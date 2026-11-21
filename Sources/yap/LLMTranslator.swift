import Foundation

// MARK: - LLMTranslator

/// Translates caption lines with an OpenAI-compatible chat model (by default GLM-5.3 Flash through
/// OpenCode Go). Each request carries the last few lines and their translations, so names, subjects
/// and the speaker's tone carry over from line to line. The captions come from speech recognition,
/// so the model is asked to translate what was most likely said.
@MainActor
final class LLMTranslator {
    struct Config {
        var apiKey: String
        var baseURL: URL
        var model: String
        /// Sent as `reasoning_effort`, unless "default".
        var reasoningEffort: String

        /// The settings from the environment, then from `.env` in the current directory, then from
        /// `~/.config/yap/.env`. Shell variables win, as with the other tools that use the same file.
        static func load() throws -> Config {
            let env = DotEnv.load()
            guard let apiKey = env["OPENCODE_API_KEY"], !apiKey.isEmpty else {
                throw CaptionTranslatorError.missingAPIKey
            }
            let base = env["OPENCODE_BASE_URL"] ?? "https://opencode.ai/inference/go/openai/v1"
            guard let baseURL = URL(string: base.hasSuffix("/") ? String(base.dropLast()) : base) else {
                throw CaptionTranslatorError.llmRequest("OPENCODE_BASE_URL isn't a URL: \(base)")
            }
            return Config(
                apiKey: apiKey,
                baseURL: baseURL,
                model: env["OPENCODE_MODEL"] ?? "glm-5.3-flash",
                reasoningEffort: env["OPENCODE_REASONING_EFFORT"] ?? "low"
            )
        }
    }

    /// How many earlier lines go with each request as context.
    static let contextLines = 4

    let config: Config
    private let systemPrompt: String
    /// OpenCode Go routes requests by session and refuses ones without it.
    private let sessionID = UUID().uuidString
    private let urlSession: URLSession
    private var history: [(source: String, translation: String)] = []

    init(config: Config, source: Locale, target: String) {
        self.config = config
        let english = Locale(identifier: "en")
        let sourceName = english.localizedString(forIdentifier: source.language.minimalIdentifier) ?? source.identifier
        let targetName = english.localizedString(forIdentifier: target) ?? target
        systemPrompt = """
        You translate live speech captions from \(sourceName) into \(targetName) (\(target)).
        The captions come from automatic speech recognition, so they may contain misheard words, wrong \
        homophones or a sentence cut in two. Translate what the speaker most likely said, using the earlier \
        lines for context (who is speaking, names, what "it" refers to).
        Translate only the new line. Output the translation alone: no notes, quotes, readings or the original text.
        """
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        urlSession = URLSession(configuration: configuration)
    }

    func translate(_ text: String) async throws -> String {
        var user = ""
        if !history.isEmpty {
            user += "Earlier lines, for context only:\n"
            for line in history {
                user += "\(line.source)\n→ \(line.translation)\n"
            }
            user += "\n"
        }
        user += "New line to translate:\n\(text)"

        var body: [String: Any] = [
            "model": config.model,
            "stream": false,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": user],
            ],
        ]
        if config.reasoningEffort != "default" {
            body["reasoning_effort"] = config.reasoningEffort
        }

        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("yap", forHTTPHeaderField: "User-Agent")
        request.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
            throw CaptionTranslatorError.llmRequest("HTTP \(status) from \(config.model): \(detail)")
        }
        let reply = try JSONDecoder().decode(ChatReply.self, from: data)
        let translation = Self.clean(reply.choices.first?.message.content ?? "")
        if !translation.isEmpty {
            history.append((text, translation))
            if history.count > Self.contextLines { history.removeFirst() }
        }
        return translation
    }

    /// The reply without any reasoning block, surrounding whitespace or quotes the model added.
    nonisolated static func clean(_ reply: String) -> String {
        var text = reply
        if let end = text.range(of: "</think>") {
            text = String(text[end.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("“", "”"), ("「", "」")] where text.count > 2 && text.hasPrefix(open) && text.hasSuffix(close) {
            let inner = text.dropFirst().dropLast()
            // Only quotes around the whole reply, not a line that starts and ends with two different quotes
            if !inner.contains(open), !inner.contains(close) { text = String(inner) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ChatReply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }
}

// MARK: - DotEnv

/// `KEY=value` settings from the environment and `.env` files. The environment wins, then `.env` in
/// the current directory, then `~/.config/yap/.env`. Empty values are skipped, so a blank line in the
/// file doesn't hide a value from somewhere else.
enum DotEnv {
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let files = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/yap/.env"),
        ]
        var values: [String: String] = [:]
        for file in files.reversed() {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            values.merge(parse(contents)) { _, new in new }
        }
        values.merge(environment.filter { !$0.value.isEmpty }) { _, new in new }
        return values
    }

    static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in contents.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            } else if let comment = value.range(of: " #") {
                value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty, !value.isEmpty { values[key] = value }
        }
        return values
    }
}
