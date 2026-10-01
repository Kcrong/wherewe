import Foundation

public struct SegmentEditRequest: Codable, Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct SegmentEditResponse: Codable, Equatable, Sendable {
    public let segment: TranscriptSegment
}

public struct TranslationTargetRequest: Codable, Equatable, Sendable {
    public let target: String

    public init(target: String) {
        self.target = target
    }
}

public struct TranslationQueuedCounts: Codable, Equatable, Sendable {
    public let transcripts: Int
    public let segments: Int
}

public struct TranslationTargetResponse: Codable, Equatable, Sendable {
    public let meetingID: Int
    public let translationTarget: String
    public let queued: TranslationQueuedCounts

    private enum CodingKeys: String, CodingKey {
        case meetingID = "meetingId"
        case translationTarget = "translation_target"
        case queued
    }
}

public enum TranslationEntityType: String, Codable, Sendable {
    case transcript
    case segment
}

public struct TranslationRetryRequest: Codable, Equatable, Sendable {
    public let entityType: TranslationEntityType
    public let entityID: Int

    public init(entityType: TranslationEntityType, entityID: Int) {
        self.entityType = entityType
        self.entityID = entityID
    }

    private enum CodingKeys: String, CodingKey {
        case entityType = "entity_type"
        case entityID = "entity_id"
    }
}

public struct TranslationRetryResponse: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let entityType: TranslationEntityType

    private enum CodingKeys: String, CodingKey {
        case accepted
        case entityType = "entity_type"
    }
}
