import Foundation

public struct AppleSpeechSettings: Codable, Equatable, Sendable {
    public var mode: String
    public var showDetails: Bool

    public init(mode: String = "live", showDetails: Bool = false) {
        self.mode = mode
        self.showDetails = showDetails
    }
}

public struct LocalTranscriptionSettings: Codable, Equatable, Sendable {
    public var provider: String
    public var model: String
    public var apple: AppleSpeechSettings?

    public init(
        provider: String = "apple",
        model: String = "system",
        apple: AppleSpeechSettings? = AppleSpeechSettings()
    ) {
        self.provider = provider
        self.model = model
        self.apple = apple
    }
}

public struct TranscriptionSettings: Codable, Equatable, Sendable {
    public var engine: String
    public var local: LocalTranscriptionSettings

    public init(engine: String = "apple", local: LocalTranscriptionSettings = LocalTranscriptionSettings()) {
        self.engine = engine
        self.local = local
    }
}

public struct TranslationSettings: Codable, Equatable, Sendable {
    public var provider: String

    public init(provider: String = "apple") {
        self.provider = provider
    }
}

public struct UserSettings: Codable, Equatable, Sendable {
    public var name: String
    public var role: String
    public var organization: String
    public var profile: String

    public init(name: String, role: String, organization: String, profile: String) {
        self.name = name
        self.role = role
        self.organization = organization
        self.profile = profile
    }
}

public struct PathSettings: Codable, Equatable, Sendable {
    public var database: String
    public var files: String

    public init(database: String, files: String) {
        self.database = database
        self.files = files
    }
}

public struct SettingsDocument: Codable, Equatable, Sendable {
    public let version: Int
    public let revision: String?
    public let configured: Bool
    public let restartRequired: Bool
    public let restartReasons: [String]
    public let environmentOverrides: [String]
    public var transcription: TranscriptionSettings
    public var translation: TranslationSettings
    public var user: UserSettings
    public var paths: PathSettings

    public var updateRequest: SettingsUpdateRequest {
        SettingsUpdateRequest(
            version: version,
            transcription: transcription,
            translation: translation,
            user: user,
            paths: paths
        )
    }
}

public struct SettingsUpdateRequest: Codable, Equatable, Sendable {
    public var version: Int
    public var transcription: TranscriptionSettings
    public var translation: TranslationSettings
    public var user: UserSettings
    public var paths: PathSettings

    public init(
        version: Int,
        transcription: TranscriptionSettings,
        translation: TranslationSettings,
        user: UserSettings,
        paths: PathSettings
    ) {
        self.version = version
        self.transcription = transcription
        self.translation = translation
        self.user = user
        self.paths = paths
    }
}

public struct SettingsEnvelope: Equatable, Sendable {
    public let document: SettingsDocument
    public let etag: String?
}

public struct LocalProviderDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let description: String?
    public let modelRequired: Bool
    public let defaultModel: String
    public let available: Bool
    public let ready: Bool
    public let reason: String?
}

public struct TranscriptionProgress: Codable, Equatable, Sendable {
    public let state: String
    public let provider: String
    public let model: String
    public let message: String?
    public let error: String?
}

public struct TranscriptionCatalogueResponse: Codable, Equatable, Sendable {
    public let localProviders: [LocalProviderDescriptor]
    public let progress: TranscriptionProgress
}

public struct PrepareTranscriptionRequest: Codable, Equatable, Sendable {
    public let provider: String
    public let model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }
}
