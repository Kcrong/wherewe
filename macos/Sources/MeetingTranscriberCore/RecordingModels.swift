import Foundation

public struct CreateMeetingRequest: Codable, Equatable, Sendable {
    public let title: String
    public let context: String
    public let language: String
    public let translationTarget: String

    public init(
        title: String,
        context: String = "",
        language: String = "en-US",
        translationTarget: String = "ko"
    ) {
        self.title = title
        self.context = context
        self.language = language
        self.translationTarget = translationTarget
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case context
        case language = "lang"
        case translationTarget = "translateTo"
    }
}

public struct CreateMeetingResponse: Codable, Equatable, Sendable {
    public let id: Int
}

public struct RecordingStatus: Codable, Equatable, Sendable {
    public let recordingMeetingID: Int?
    public let selectionLocked: Bool
    public let recordingGeneration: Int64?
    public let recordingOwnerConnected: Bool
    public let recordingOwnedByRequester: Bool

    private enum CodingKeys: String, CodingKey {
        case recordingMeetingID = "recordingMeetingId"
        case selectionLocked
        case recordingGeneration
        case recordingOwnerConnected
        case recordingOwnedByRequester
    }
}

public struct RecordingPreparation: Codable, Equatable, Sendable {
    public let state: String
    public let provider: String
    public let requestedLocale: String?
    public let message: String?
    public let progress: Double
}

public struct StartRecordingRequest: Codable, Equatable, Sendable {
    public let socketID: String
    public let language: String
    public let translationTarget: String

    public init(socketID: String, language: String, translationTarget: String) {
        self.socketID = socketID
        self.language = language
        self.translationTarget = translationTarget
    }

    private enum CodingKeys: String, CodingKey {
        case socketID = "socketId"
        case language = "lang"
        case translationTarget = "translateTo"
    }
}

public struct StartRecordingResponse: Codable, Equatable, Sendable {
    public let success: Bool
    public let language: String
    public let engine: String
    public let generation: Int64
    public let provider: String
    public let model: String
    public let mode: String
    public let preparedLocale: String
    public let alreadyRecording: Bool

    private enum CodingKeys: String, CodingKey {
        case success
        case language = "lang"
        case engine
        case generation
        case provider
        case model
        case mode
        case preparedLocale
        case alreadyRecording
    }
}

public struct FinalizeRecordingRequest: Codable, Equatable, Sendable {
    public let meetingID: Int
    public let generation: Int64
    public let socketID: String

    public init(meetingID: Int, generation: Int64, socketID: String) {
        self.meetingID = meetingID
        self.generation = generation
        self.socketID = socketID
    }

    private enum CodingKeys: String, CodingKey {
        case meetingID = "meetingId"
        case generation
        case socketID = "socketId"
    }
}

public struct SuccessResponse: Codable, Equatable, Sendable {
    public let success: Bool
}
