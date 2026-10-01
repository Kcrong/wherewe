import Foundation

public struct UpdateMeetingRequest: Codable, Equatable, Sendable {
    public let title: String?
    public let context: String?

    public init(title: String? = nil, context: String? = nil) {
        self.title = title
        self.context = context
    }
}

public struct UpdateMeetingContextRequest: Codable, Equatable, Sendable {
    public let context: String

    public init(context: String) {
        self.context = context
    }
}

public struct DeleteMeetingRequest: Codable, Equatable, Sendable {
    public let socketID: String?

    public init(socketID: String?) {
        self.socketID = socketID
    }

    private enum CodingKeys: String, CodingKey {
        case socketID = "socketId"
    }
}
