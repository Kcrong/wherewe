import Foundation

public enum TranslationStatus: String, Codable, Sendable {
    case idle
    case pending
    case succeeded
    case failed
    case notRequired = "not_required"
}

public struct TranslationErrorDetail: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
}

public struct TranscriptRow: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let meetingID: Int
    public let resultID: String?
    public let speaker: String?
    public let channelID: String?
    public let text: String
    public let translation: String?
    public let translationTarget: String?
    public let translationProvider: String?
    public let translationSourceHash: String?
    public let translationSourceVersion: Int
    public let translationStatus: TranslationStatus
    public let translationError: TranslationErrorDetail?
    public let translationAttempts: Int
    public let translationUpdatedAt: String?
    public let languageCode: String?
    public let alternatives: [String]
    public let confidence: Double?
    public let transcriptionEngine: String?
    public let transcriptionProvider: String?
    public let transcriptionModel: String?
    public let transcriptionMode: String?
    public let resultStage: String?
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case meetingID = "meeting_id"
        case resultID = "result_id"
        case speaker
        case channelID = "channel_id"
        case text
        case translation
        case translationTarget = "translation_target"
        case translationProvider = "translation_provider"
        case translationSourceHash = "translation_source_hash"
        case translationSourceVersion = "translation_source_version"
        case translationStatus = "translation_status"
        case translationError = "translation_error"
        case translationAttempts = "translation_attempts"
        case translationUpdatedAt = "translation_updated_at"
        case languageCode = "lang_code"
        case alternatives
        case confidence
        case transcriptionEngine = "transcription_engine"
        case transcriptionProvider = "transcription_provider"
        case transcriptionModel = "transcription_model"
        case transcriptionMode = "transcription_mode"
        case resultStage = "result_stage"
        case createdAt = "created_at"
    }
}

public struct SegmentCorrection: Codable, Equatable, Sendable {
    public let from: String
    public let to: String
    public let reason: String?
}

public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let meetingID: Int
    public let channelID: String?
    public let speaker: String?
    public let text: String
    public let translation: String?
    public let translationTarget: String?
    public let translationProvider: String?
    public let translationSourceHash: String?
    public let translationSourceVersion: Int
    public let translationStatus: TranslationStatus
    public let translationError: TranslationErrorDetail?
    public let translationAttempts: Int
    public let translationUpdatedAt: String?
    public let languageCode: String?
    public let corrections: [SegmentCorrection]
    public let sourceIDs: [String]
    public let orderIndex: Double
    public let createdAt: String?
    public let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case meetingID = "meeting_id"
        case channelID = "channel_id"
        case speaker
        case text
        case translation
        case translationTarget = "translation_target"
        case translationProvider = "translation_provider"
        case translationSourceHash = "translation_source_hash"
        case translationSourceVersion = "translation_source_version"
        case translationStatus = "translation_status"
        case translationError = "translation_error"
        case translationAttempts = "translation_attempts"
        case translationUpdatedAt = "translation_updated_at"
        case languageCode = "lang_code"
        case corrections
        case sourceIDs = "source_ids"
        case orderIndex = "order_index"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct MeetingDocument: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let meetingID: Int
    public let name: String
    public let format: String
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case meetingID = "meeting_id"
        case name
        case format
        case createdAt = "created_at"
    }
}

public struct MeetingDetail: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let context: String
    public let language: String
    public let translationTarget: String
    public let createdAt: String?
    public let endedAt: String?
    public let transcripts: [TranscriptRow]
    public let documents: [MeetingDocument]
    public let segments: [TranscriptSegment]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case context
        case language = "lang"
        case translationTarget = "translate_to"
        case createdAt = "created_at"
        case endedAt = "ended_at"
        case transcripts
        case documents
        case segments
    }
}

public struct TranscriptStateResponse: Codable, Equatable, Sendable {
    public let meetingID: Int
    public let translationTarget: String
    public let selectedTranslationProvider: String
    public let transcripts: [TranscriptRow]
    public let segments: [TranscriptSegment]

    private enum CodingKeys: String, CodingKey {
        case meetingID = "meetingId"
        case translationTarget = "translation_target"
        case selectedTranslationProvider = "selected_translation_provider"
        case transcripts
        case segments
    }
}

public struct TranscriptionEvent: Codable, Equatable, Sendable {
    public let meetingID: Int?
    public let generation: Int64?
    public let databaseID: Int?
    public let resultID: String
    public let transcript: String
    public let isPartial: Bool
    public let resultStage: String?
    public let languageCode: String?
    public let speaker: String?
    public let channelID: String?
    public let alternatives: [String]?
    public let confidence: Double?
    public let transcriptionEngine: String?
    public let transcriptionProvider: String?
    public let transcriptionModel: String?
    public let transcriptionMode: String?
    public let translation: String?
    public let translationTarget: String?
    public let translationProvider: String?
    public let translationSourceHash: String?
    public let translationSourceVersion: Int?
    public let translationStatus: TranslationStatus?
    public let translationError: TranslationErrorDetail?
    public let translationAttempts: Int?
    public let translationUpdatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case meetingID = "meetingId"
        case generation
        case databaseID = "dbId"
        case resultID = "resultId"
        case transcript
        case isPartial
        case resultStage
        case languageCode
        case speaker
        case channelID = "channelId"
        case alternatives
        case confidence
        case transcriptionEngine = "transcription_engine"
        case transcriptionProvider = "transcription_provider"
        case transcriptionModel = "transcription_model"
        case transcriptionMode = "transcription_mode"
        case translation
        case translationTarget = "translation_target"
        case translationProvider = "translation_provider"
        case translationSourceHash = "translation_source_hash"
        case translationSourceVersion = "translation_source_version"
        case translationStatus = "translation_status"
        case translationError = "translation_error"
        case translationAttempts = "translation_attempts"
        case translationUpdatedAt = "translation_updated_at"
    }
}

public struct LiveTranscriptRow: Equatable, Identifiable, Sendable {
    public var id: String { resultID }
    public let databaseID: Int?
    public let resultID: String
    public let text: String
    public let isPartial: Bool
    public let speaker: String?
    public let languageCode: String?
    public let channelID: String?
    public let alternatives: [String]
    public let confidence: Double?
    public let transcriptionEngine: String?
    public let transcriptionProvider: String?
    public let transcriptionModel: String?
    public let transcriptionMode: String?
    public let resultStage: String?
    public let translation: String?
    public let translationTarget: String?
    public let translationProvider: String?
    public let translationSourceHash: String?
    public let translationSourceVersion: Int
    public let translationStatus: TranslationStatus
    public let translationError: TranslationErrorDetail?
    public let translationAttempts: Int
    public let translationUpdatedAt: String?
}
