import ArgumentParser
import Foundation
@preconcurrency import Translation

// MARK: - CaptionTranslator

/// Which translator --translate uses.
enum TranslatorBackend: String, ExpressibleByArgument, CaseIterable {
    /// Apple's on-device Translation framework.
    case apple
    /// A chat model through an OpenAI-compatible API (OpenCode; settings in .env).
    case llm
}

/// Translates final caption lines, either on-device with Apple's Translation framework or with an
/// LLM, and with --correct has the LLM fix misheard words in them first. With the LLM, Apple's
/// translation is also set up when its languages are installed, and used for any line the LLM request
/// fails on. Apple's language pair has to be installed in System Settings first; command-line tools
/// can't download it themselves.
@MainActor
final class CaptionTranslator {
    struct Result {
        /// The line, corrected when --correct fixed something.
        var text: String
        var translation: String?
    }

    private let llm: LLMTranslator?
    private nonisolated(unsafe) let session: TranslationSession?
    private var reportedFailure = false

    private init(llm: LLMTranslator?, session: TranslationSession?) {
        self.llm = llm
        self.session = session
    }

    /// Whether lines are corrected, which changes their text after Whisper wrote them.
    var corrects: Bool { llm?.corrects ?? false }

    /// Translates into `target` (if any) with `backend`. With `corrects`, the LLM is used for both.
    static func make(from source: Locale, to target: String?, backend: TranslatorBackend = .apple, corrects: Bool = false) async throws -> CaptionTranslator {
        if backend == .apple, !corrects, let target {
            let translator = try await CaptionTranslator(llm: nil, session: appleSession(from: source, to: target))
            // The translation model loads on the first request; do that now rather than on the first caption
            _ = try? await translator.session?.translate("こんにちは")
            return translator
        }
        let llm = LLMTranslator(config: try LLMTranslator.Config.load(), source: source, target: target, corrects: corrects)
        let fallback: TranslationSession? = if let target { try? await appleSession(from: source, to: target) } else { nil }
        return CaptionTranslator(llm: llm, session: fallback)
    }

    /// Sends a test request to the LLM, if there is one, so a wrong key or model is reported at the
    /// start rather than on the first caption. It goes to a throwaway translator, so it isn't context
    /// for the real lines. Run it alongside the captions: it takes about a second.
    func verify() async throws {
        guard let llm else { return }
        do {
            _ = try await LLMTranslator(config: llm.config, source: llm.source, target: llm.target, corrects: llm.corrects).process("こんにちは")
        } catch let error as CaptionTranslatorError {
            throw error
        } catch {
            throw CaptionTranslatorError.llmRequest(error.localizedDescription)
        }
    }

    private static func appleSession(from source: Locale, to target: String) async throws -> TranslationSession {
        let sourceLanguage = source.language
        let targetLanguage = Locale.Language(identifier: target)
        let availability = LanguageAvailability()
        switch await availability.status(from: sourceLanguage, to: targetLanguage) {
        case .installed:
            return TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        case .supported:
            throw CaptionTranslatorError.notInstalled(source: sourceLanguage, target: targetLanguage)
        default:
            let supported = await availability.supportedLanguages
                .filter { $0.minimalIdentifier != sourceLanguage.minimalIdentifier }
                .map(Self.code)
            throw CaptionTranslatorError.unsupported(source: sourceLanguage, target: targetLanguage, supported: supported)
        }
    }

    /// The code to pass to --translate: Chinese needs its script (zh-Hans, zh-Hant), other languages don't.
    private static func code(_ language: Locale.Language) -> String {
        if language.languageCode == .chinese, let script = language.maximalIdentifier.split(separator: "-").dropFirst().first {
            return "zh-\(script)"
        }
        return language.minimalIdentifier
    }

    /// `text`, corrected with --correct, and its translation, or nil if it couldn't be translated or
    /// came back empty (which would add an empty line to a subtitle cue). The first failure is reported
    /// on stderr, so a translation that stops working isn't silent.
    ///
    /// `appleHeard` is what Apple's transcriber heard for about the same audio. With --correct it
    /// goes to the LLM as evidence for the right kanji.
    func process(_ text: String, appleHeard: String = "") async -> Result {
        if let llm {
            do {
                let reply = try await llm.process(text, otherHearing: appleHeard)
                let corrected = reply.corrected ?? text
                // Without a translation the LLM was only asked to correct, or the translation came back empty
                if reply.translation != nil || session == nil {
                    return Result(text: corrected, translation: reply.translation)
                }
                return await Result(text: corrected, translation: appleTranslation(of: corrected))
            } catch {
                report(error, fallingBack: session != nil)
            }
        }
        return await Result(text: text, translation: appleTranslation(of: text))
    }

    private func appleTranslation(of text: String) async -> String? {
        guard let session else { return nil }
        do {
            let translation = try await session.translate(text).targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            return translation.isEmpty ? nil : translation
        } catch {
            report(error, fallingBack: false)
            return nil
        }
    }

    private func report(_ error: Error, fallingBack: Bool) {
        guard !reportedFailure else { return }
        reportedFailure = true
        let fallback = fallingBack ? " Using Apple's translation for lines the LLM fails on." : corrects ? " Lines the LLM fails on are left as heard." : ""
        FileHandle.standardError.write(Data("Translation failed: \(error.localizedDescription)\(fallback)\n".utf8))
    }
}

enum CaptionTranslatorError: Swift.Error, LocalizedError {
    case notInstalled(source: Locale.Language, target: Locale.Language)
    case unsupported(source: Locale.Language, target: Locale.Language, supported: [String])
    case missingAPIKey
    case llmRequest(String)

    var errorDescription: String? {
        switch self {
        case let .notInstalled(source, target):
            "Translation from \(Self.name(source)) to \(Self.name(target)) needs its languages installed. Add them in System Settings > General > Language & Region > Translation Languages."
        case let .unsupported(source, target, supported):
            "Translation from \(Self.name(source)) to \(Self.name(target)) isn't supported. Available languages: \(supported.sorted().joined(separator: ", "))."
        case .missingAPIKey:
            "--translator llm and --correct need OPENCODE_API_KEY, in the environment or in a .env file in the current directory or ~/.config/yap/."
        case let .llmRequest(detail):
            "The LLM translator isn't working: \(detail)"
        }
    }

    /// The language's English name, like the rest of the command-line output.
    private static func name(_ language: Locale.Language) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }
}
