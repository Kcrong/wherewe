import Foundation

public enum NativeProtocol {
    public static let service = "wherewe"
    public static let version = 1
}

public struct NativeServiceHealth: Codable, Equatable, Sendable {
    public let service: String
    public let applicationVersion: String
    public let protocolVersion: Int
    public let state: State
    public let configured: Bool
    public let setupRequired: Bool
    public let realtimeAvailable: Bool

    public enum State: String, Codable, Sendable {
        case ready
        case setupRequired = "setup-required"
    }

    public init(
        service: String,
        applicationVersion: String,
        protocolVersion: Int,
        state: State,
        configured: Bool,
        setupRequired: Bool,
        realtimeAvailable: Bool
    ) {
        self.service = service
        self.applicationVersion = applicationVersion
        self.protocolVersion = protocolVersion
        self.state = state
        self.configured = configured
        self.setupRequired = setupRequired
        self.realtimeAvailable = realtimeAvailable
    }

    public func validateCompatibility() throws {
        guard service == NativeProtocol.service else {
            throw NativeServiceContractError.incompatibleService(service)
        }
        guard protocolVersion == NativeProtocol.version else {
            throw NativeServiceContractError.incompatibleProtocol(
                expected: NativeProtocol.version,
                actual: protocolVersion
            )
        }
        guard configured != setupRequired,
              state == (configured ? .ready : .setupRequired),
              realtimeAvailable == configured else {
            throw NativeServiceContractError.inconsistentHealth
        }
    }
}

public struct MeetingSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let lang: String?
    public let translateTo: String?
    public let createdAt: String?
    public let recordingStartedAt: String?
    public let recordingEndedAt: String?

    public init(
        id: Int,
        title: String,
        lang: String? = nil,
        translateTo: String? = nil,
        createdAt: String? = nil,
        recordingStartedAt: String? = nil,
        recordingEndedAt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.lang = lang
        self.translateTo = translateTo
        self.createdAt = createdAt
        self.recordingStartedAt = recordingStartedAt
        self.recordingEndedAt = recordingEndedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case lang
        case translateTo = "translate_to"
        case createdAt = "created_at"
        case recordingStartedAt = "recording_started_at"
        case recordingEndedAt = "recording_ended_at"
    }
}

public enum NativeServiceContractError: Error, Equatable, LocalizedError, Sendable {
    case incompatibleService(String)
    case incompatibleProtocol(expected: Int, actual: Int)
    case inconsistentHealth

    public var errorDescription: String? {
        switch self {
        case .incompatibleService:
            return "The native service identity is incompatible with this application."
        case let .incompatibleProtocol(expected, actual):
            return "The native service contract is incompatible (expected \(expected), received \(actual))."
        case .inconsistentHealth:
            return "The native service returned an inconsistent health state."
        }
    }
}

package struct MeetingSelectionState: Equatable, Sendable {
    package private(set) var selectedID: Int?
    package private(set) var loadedID: Int?

    @discardableResult
    package mutating func select(_ id: Int?) -> Bool {
        guard selectedID != id else { return false }
        selectedID = id
        loadedID = nil
        return true
    }

    package mutating func beginLoading() -> Int? {
        loadedID = nil
        return selectedID
    }

    @discardableResult
    package mutating func finishLoading(_ id: Int) -> Bool {
        guard selectedID == id else { return false }
        loadedID = id
        return true
    }

    package var mutationID: Int? {
        guard let selectedID, loadedID == selectedID else { return nil }
        return selectedID
    }
}
