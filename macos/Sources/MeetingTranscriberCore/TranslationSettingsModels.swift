import Foundation

public struct TranslationLanguageStatus: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let installed: Bool
    public let status: String
}

public struct TranslationPairStatus: Codable, Equatable, Sendable {
    public let source: String
    public let target: String
    public let status: String
    public let errorCode: String?
    public let error: String?
}

public struct TranslationLanguagesResponse: Codable, Equatable, Sendable {
    public let languages: [TranslationLanguageStatus]
    public let pairs: [String: TranslationPairStatus]
}

public struct OpenSettingsResponse: Codable, Equatable, Sendable {
    public let opened: Bool
}
