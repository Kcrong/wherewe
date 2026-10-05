import Foundation

public struct StartTranscriptionRequest: Equatable, Sendable {
    public let meetingID: Int
    public let generation: Int64
    public let language: String
    public let translationTarget: String
    public let sampleRate: Double
    public let channelCount: Int

    public init(
        meetingID: Int,
        generation: Int64,
        language: String,
        translationTarget: String,
        sampleRate: Double,
        channelCount: Int
    ) {
        self.meetingID = meetingID
        self.generation = generation
        self.language = language
        self.translationTarget = translationTarget
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public struct ReadyForAudio: Codable, Equatable, Sendable {
    public let engine: String
    public let provider: String
    public let model: String
    public let generation: Int64
}

public struct RealtimeAcknowledgement: Codable, Equatable, Sendable {
    public let success: Bool
    public let code: String?
    public let meetingID: Int?
    public let generation: Int64?
    public let audioByteCount: Int?

    public init(
        success: Bool,
        code: String?,
        meetingID: Int?,
        generation: Int64?,
        audioByteCount: Int? = nil
    ) {
        self.success = success
        self.code = code
        self.meetingID = meetingID
        self.generation = generation
        self.audioByteCount = audioByteCount
    }

    private enum CodingKeys: String, CodingKey {
        case success
        case code
        case meetingID = "meetingId"
        case generation
        case audioByteCount
    }
}

public enum RealtimeEventName: String, CaseIterable, Sendable {
    case connected
    case disconnected
    case readyForAudio
    case transcription
    case transcribeError
    case translationUpdated
    case translationTargetChanged
    case segmentsUpdated
}

public struct RealtimeMessage: Equatable, Sendable {
    public let name: RealtimeEventName
    public let payload: Data?

    public init(name: RealtimeEventName, payload: Data? = nil) {
        self.name = name
        self.payload = payload
    }

    public func decode<Value: Decodable>(
        _ type: Value.Type,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> Value {
        guard let payload else { throw NativeServiceError.decoding }
        return try decoder.decode(type, from: payload)
    }
}

public enum RealtimeClientError: Error, Equatable, LocalizedError, Sendable {
    case connectionTimedOut
    case disconnected
    case invalidPayload
    case acknowledgementTimedOut

    public var errorDescription: String? {
        switch self {
        case .connectionTimedOut:
            return "The realtime connection did not become ready in time."
        case .disconnected:
            return "The realtime connection is not available."
        case .invalidPayload:
            return "The realtime service returned an invalid payload."
        case .acknowledgementTimedOut:
            return "The realtime service did not acknowledge the request in time."
        }
    }
}

public protocol RealtimeServing: Sendable {
    var messages: AsyncStream<RealtimeMessage> { get }
    var clientID: String? { get }

    func connect() async throws
    func disconnect()
    func startTranscription(_ request: StartTranscriptionRequest)
    func sendAudio(_ data: Data) throws
    func audioBarrier(meetingID: Int, generation: Int64) async throws -> RealtimeAcknowledgement
    func stopTranscription(meetingID: Int, generation: Int64) async throws -> RealtimeAcknowledgement
}
