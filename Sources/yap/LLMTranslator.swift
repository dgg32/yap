import Foundation

// MARK: - LLMTranslator

/// Translates caption lines, and with `corrects` also fixes misheard words in them, with an
/// OpenAI-compatible chat model (by default GLM-5.3 Flash through OpenCode Go). Each request carries
/// the last few lines, so names, subjects and the topic carry over from line to line. The captions
/// come from speech recognition, so the model is asked to translate what was most likely said.
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

    struct Reply {
        /// The corrected line; nil when not correcting or when the correction was rejected.
        var corrected: String?
        var translation: String?
    }

    /// How many earlier lines go with each request as context.
    static let contextLines = 4

    let config: Config
    let source: Locale
    let target: String?
    let corrects: Bool
    private let translates: Bool
    private let systemPrompt: String
    /// OpenCode Go routes requests by session and refuses ones without it.
    private let sessionID = UUID().uuidString
    private let urlSession: URLSession
    /// Earlier lines (corrected, when correcting) and their translations.
    private(set) var history: [(source: String, translation: String?)] = []

    init(config: Config, source: Locale, target: String?, corrects: Bool = false) {
        self.config = config
        self.source = source
        self.target = target
        self.corrects = corrects
        translates = target != nil
        let english = Locale(identifier: "en")
        let sourceName = english.localizedString(forIdentifier: source.language.minimalIdentifier) ?? source.identifier
        let targetName = target.map { "\(english.localizedString(forIdentifier: $0) ?? $0) (\($0))" } ?? ""
        let asr = """
        The captions come from automatic speech recognition, so they may contain misheard words, wrong \
        homophones (the wrong kanji for the right sound) or a sentence cut in two.
        """
        if corrects {
            let correction = """
            "corrected": the line with recognition errors fixed. Only change a word when it is very likely \
            misheard: the fix must be read exactly the same (a homophone in different kanji), and fit the context clearly better. \
            When a second recognizer's text is given, it is strong evidence: where the two write the same \
            sound in different kanji, prefer the one that fits the context. \
            Check every word: one line can have several such errors, and a fix found in one place often \
            applies to the same sound elsewhere in the line or the earlier lines. Keep everything else exactly as it is: wording, numbers, punctuation and kana/kanji spelling. \
            If unsure, leave the word as it is.
            """
            if translates {
                systemPrompt = """
                You correct live speech captions in \(sourceName) and translate them into \(targetName).
                \(asr)
                Use the earlier lines for context (topic, who is speaking, names). For the new line, give:
                1. \(correction)
                2. "translation": the translation of the corrected line alone, with no notes or readings.
                Reply with JSON only: {"corrected": "...", "translation": "..."}
                """
            } else {
                systemPrompt = """
                You correct live speech captions in \(sourceName).
                \(asr)
                Use the earlier lines for context (topic, who is speaking, names). For the new line, give
                \(correction)
                Reply with JSON only: {"corrected": "..."}
                """
            }
        } else {
            systemPrompt = """
            You translate live speech captions from \(sourceName) into \(targetName).
            \(asr) Translate what the speaker most likely said, using the earlier lines for context \
            (who is speaking, names, what "it" refers to).
            Translate only the new line. Output the translation alone: no notes, quotes, readings or the original text.
            """
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        urlSession = URLSession(configuration: configuration)
    }

    /// Corrects and/or translates `text`. The line goes into the context of the next requests even
    /// when this one fails (as heard), so the context stays in step with the captions.
    ///
    /// `otherHearing` is another recognizer's text for about the same audio (Apple's, when the preview
    /// runs). With `corrects`, it's sent along when it differs from `text`.
    func process(_ text: String, otherHearing: String = "") async throws -> Reply {
        let reply: Reply
        do {
            reply = try await request(text, otherHearing: otherHearing)
        } catch {
            remember(text, translation: nil)
            throw error
        }
        remember(reply.corrected ?? text, translation: reply.translation)
        return reply
    }

    private func remember(_ source: String, translation: String?) {
        history.append((source, translation))
        if history.count > Self.contextLines { history.removeFirst() }
    }

    private func request(_ text: String, otherHearing: String) async throws -> Reply {
        var user = ""
        if !history.isEmpty {
            user += "Earlier lines, for context only:\n"
            for line in history {
                user += line.source + "\n"
                if let translation = line.translation { user += "→ \(translation)\n" }
            }
            user += "\n"
        }
        user += corrects ? "New line:\n\(text)" : "New line to translate:\n\(text)"
        if corrects, Self.differs(otherHearing, from: text) {
            user += "\n\nA second recognizer heard about the same audio (it may cover a little more or less) as:\n\(otherHearing)"
        }

        var body: [String: Any] = [
            "model": config.model,
            "stream": false,
            "temperature": corrects ? 0 : 0.3,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": user],
            ],
        ]
        if corrects {
            body["response_format"] = ["type": "json_object"]
        }
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
        let content = try JSONDecoder().decode(ChatReply.self, from: data).choices.first?.message.content ?? ""

        var reply = Reply()
        if corrects {
            guard let fields = Self.jsonObject(in: content) else {
                throw CaptionTranslatorError.llmRequest("\(config.model) didn't reply with JSON: \(content.prefix(200))")
            }
            if let corrected = fields["corrected"].map(Self.clean), !corrected.isEmpty, corrected != text {
                if Self.soundsAlike(text, corrected) {
                    reply.corrected = corrected
                    DebugFilters.corrected(text, to: corrected, otherHearing: Self.differs(otherHearing, from: text) ? otherHearing : "")
                } else {
                    DebugFilters.correctionRejected(text, corrected)
                }
            }
            reply.translation = fields["translation"].map(Self.clean).flatMap { $0.isEmpty ? nil : $0 }
        } else {
            let translation = Self.clean(content)
            reply.translation = translation.isEmpty ? nil : translation
        }
        return reply
    }

    /// Whether the other recognizer's text is worth sending: present, and not the same once punctuation
    /// and spaces are ignored.
    nonisolated static func differs(_ other: String, from text: String) -> Bool {
        func letters(_ s: String) -> String { String(s.filter { $0.isLetter || $0.isNumber }) }
        let other = letters(other)
        return !other.isEmpty && other != letters(text)
    }

    /// The string fields of the JSON object in `reply`, which may be wrapped in a code fence or a
    /// reasoning block.
    nonisolated static func jsonObject(in reply: String) -> [String: String]? {
        var text = reply
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)) as? [String: Any]
        else { return nil }
        return object.compactMapValues { $0 as? String }
    }

    /// Whether `corrected` reads the same as `heard`: a correction may swap the kanji of a misheard
    /// word (構成 → 更生, both こうせい), but not change what was said. Even a one-sound difference is
    /// refused, because that's how the model "fixes" a correct word into a plausible wrong one
    /// (公正 → 公平). Compared as hiragana, ignoring punctuation and spaces.
    nonisolated static func soundsAlike(_ heard: String, _ corrected: String) -> Bool {
        func sounds(_ text: String) -> String {
            String(JapaneseReading.hiragana(text).filter { $0.isLetter || $0.isNumber })
        }
        return sounds(heard) == sounds(corrected)
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
            if let quote = value.first, quote == "\"" || quote == "'",
               let close = value.dropFirst().firstIndex(of: quote) {
                // A quoted value ends at its closing quote; anything after it (a comment) is dropped
                value = String(value[value.index(after: value.startIndex)..<close])
            } else if let comment = value.range(of: " #") {
                value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty, !value.isEmpty { values[key] = value }
        }
        return values
    }
}
