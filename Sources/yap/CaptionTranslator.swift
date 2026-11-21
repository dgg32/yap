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
/// LLM. With the LLM, Apple's translation is also set up when its languages are installed, and used
/// for any line the LLM request fails on. Apple's language pair has to be installed in System
/// Settings first; command-line tools can't download it themselves.
@MainActor
final class CaptionTranslator {
    private let llm: LLMTranslator?
    private nonisolated(unsafe) let session: TranslationSession?
    private var reportedFailure = false

    private init(llm: LLMTranslator?, session: TranslationSession?) {
        self.llm = llm
        self.session = session
    }

    /// A short description for the startup message, such as "glm-5.3-flash".
    var name: String { llm?.config.model ?? "Apple Translation" }

    static func make(from source: Locale, to target: String, backend: TranslatorBackend = .apple) async throws -> CaptionTranslator {
        switch backend {
        case .apple:
            let translator = try await CaptionTranslator(llm: nil, session: appleSession(from: source, to: target))
            // The translation model loads on the first request; do that now rather than on the first caption
            _ = try? await translator.session?.translate("こんにちは")
            return translator
        case .llm:
            let llm = LLMTranslator(config: try LLMTranslator.Config.load(), source: source, target: target)
            // A first request checks the key and the model now, rather than on the first caption.
            // It goes to a throwaway translator so it isn't context for the real lines.
            do {
                _ = try await LLMTranslator(config: llm.config, source: source, target: target).translate("こんにちは")
            } catch let error as CaptionTranslatorError {
                throw error
            } catch {
                throw CaptionTranslatorError.llmRequest(error.localizedDescription)
            }
            let fallback = try? await appleSession(from: source, to: target)
            return CaptionTranslator(llm: llm, session: fallback)
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

    /// The translation of `text`, or nil if it couldn't be translated or came back empty (which would
    /// add an empty line to a subtitle cue). The first failure is reported on stderr, so a translation
    /// that stops working isn't silent.
    func translate(_ text: String) async -> String? {
        if let llm {
            do {
                let translation = try await llm.translate(text)
                if !translation.isEmpty { return translation }
            } catch {
                report(error, fallingBack: session != nil)
            }
        }
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
        let fallback = fallingBack ? " Using Apple's translation for lines the LLM fails on." : ""
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
            "--translator llm needs OPENCODE_API_KEY, in the environment or in a .env file in the current directory or ~/.config/yap/."
        case let .llmRequest(detail):
            "The LLM translator isn't working: \(detail)"
        }
    }

    /// The language's English name, like the rest of the command-line output.
    private static func name(_ language: Locale.Language) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }
}
