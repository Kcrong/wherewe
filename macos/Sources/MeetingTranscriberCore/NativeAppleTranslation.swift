import Foundation
import Translation

struct NativeTranslationPair: Hashable, Sendable {
    let source: String
    let target: String
}

enum NativeAppleTranslationError: Error, LocalizedError {
    case unsupportedLanguage(String)
    case unsupportedPair(String, String)
    case notInstalled(String, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .unsupportedLanguage(language): "Apple Translation does not support \(language)."
        case let .unsupportedPair(source, target): "Apple Translation does not support \(source) to \(target)."
        case let .notInstalled(source, target): "Install Apple Translation language packs for \(source) and \(target)."
        case .invalidResponse: "Apple Translation returned an invalid response."
        }
    }
}

protocol NativeTranslationServing: Sendable {
    func status(source: String, target: String) async throws -> String
    func translate(_ text: String, source: String, target: String) async throws -> String
    func reset() async
}

actor NativeAppleTranslation: NativeTranslationServing {
    func status(source: String, target: String) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw NativeAppleTranslationError.unsupportedPair(source, target)
        }
        return try await NativeAppleTranslationEngine.status(source: source, target: target)
    }

    func translate(_ text: String, source: String, target: String) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw NativeAppleTranslationError.unsupportedPair(source, target)
        }
        return try await NativeAppleTranslationEngine.translate(text, source: source, target: target)
    }

    func reset() async {}
}

@available(macOS 26.0, *)
private enum NativeAppleTranslationEngine {
    private static let supported = Set(["en", "ko", "ja", "zh"])

    static func status(source: String, target: String) async throws -> String {
        let pair = try languages(source: source, target: target)
        if pair.source == pair.target { return "installed" }
        let availability = LanguageAvailability()
        let value = await availability.status(
            from: Locale.Language(identifier: pair.source),
            to: Locale.Language(identifier: pair.target)
        )
        return String(describing: value)
    }

    static func translate(_ text: String, source: String, target: String) async throws -> String {
        let pair = try languages(source: source, target: target)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if pair.source == pair.target { return value }
        let state = try await status(source: pair.source, target: pair.target)
        if state == "unsupported" { throw NativeAppleTranslationError.unsupportedPair(pair.source, pair.target) }
        guard state == "installed" else { throw NativeAppleTranslationError.notInstalled(pair.source, pair.target) }
        let session = TranslationSession(
            installedSource: Locale.Language(identifier: pair.source),
            target: Locale.Language(identifier: pair.target)
        )
        let requests = [TranslationSession.Request(sourceText: value, clientIdentifier: "single")]
        let responses = try await session.translations(from: requests)
        guard let translated = responses.first(where: { $0.clientIdentifier == "single" })?.targetText,
              !translated.isEmpty else {
            throw NativeAppleTranslationError.invalidResponse
        }
        return translated
    }

    private static func languages(source: String, target: String) throws -> NativeTranslationPair {
        let source = canonical(source)
        let target = canonical(target)
        guard supported.contains(source) else { throw NativeAppleTranslationError.unsupportedLanguage(source) }
        guard supported.contains(target) else { throw NativeAppleTranslationError.unsupportedLanguage(target) }
        return NativeTranslationPair(source: source, target: target)
    }

    private static func canonical(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: "-")
            .lowercased().split(separator: "-").first.map(String.init) ?? ""
    }
}
