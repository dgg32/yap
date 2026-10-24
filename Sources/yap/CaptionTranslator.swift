import Foundation
@preconcurrency import Translation

// MARK: - CaptionTranslator

/// Translates final caption lines on-device with Apple's Translation framework. The language pair has
/// to be installed in System Settings first; command-line tools can't download it themselves.
@MainActor
final class CaptionTranslator {
    private nonisolated(unsafe) let session: TranslationSession
    private var reportedFailure = false

    private init(session: TranslationSession) {
        self.session = session
    }

    static func make(from source: Locale, to target: String) async throws -> CaptionTranslator {
        let sourceLanguage = source.language
        let targetLanguage = Locale.Language(identifier: target)
        let availability = LanguageAvailability()
        switch await availability.status(from: sourceLanguage, to: targetLanguage) {
        case .installed:
            let translator = CaptionTranslator(session: TranslationSession(installedSource: sourceLanguage, target: targetLanguage))
            // The translation model loads on the first request; do that now rather than on the first caption
            _ = try? await translator.session.translate("こんにちは")
            return translator
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

    /// The translation of `text`, or nil if it couldn't be translated. The first failure is reported
    /// on stderr, so a translation that stops working isn't silent.
    func translate(_ text: String) async -> String? {
        do {
            return try await session.translate(text).targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            if !reportedFailure {
                reportedFailure = true
                FileHandle.standardError.write(Data("Translation failed: \(error.localizedDescription)\n".utf8))
            }
            return nil
        }
    }
}

enum CaptionTranslatorError: Swift.Error, LocalizedError {
    case notInstalled(source: Locale.Language, target: Locale.Language)
    case unsupported(source: Locale.Language, target: Locale.Language, supported: [String])

    var errorDescription: String? {
        switch self {
        case let .notInstalled(source, target):
            "Translation from \(Self.name(source)) to \(Self.name(target)) needs its languages installed. Add them in System Settings > General > Language & Region > Translation Languages."
        case let .unsupported(source, target, supported):
            "Translation from \(Self.name(source)) to \(Self.name(target)) isn't supported. Available languages: \(supported.sorted().joined(separator: ", "))."
        }
    }

    /// The language's English name, like the rest of the command-line output.
    private static func name(_ language: Locale.Language) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }
}
