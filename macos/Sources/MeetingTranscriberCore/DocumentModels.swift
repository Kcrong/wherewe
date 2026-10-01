import Foundation

public struct UploadedDocument: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let format: String
    public let size: Int
}

public struct UploadResponse: Codable, Equatable, Sendable {
    public let success: Bool
    public let id: Int
    public let name: String
    public let format: String
}

public struct DocumentContent: Equatable, Sendable {
    public let data: Data
    public let contentType: String?
    public let contentDisposition: String?
}

public struct GlossaryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let phrase: String
    public let displayAs: String?
    public let language: String
    public let meetingID: Int?
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case phrase
        case displayAs = "display_as"
        case language = "lang"
        case meetingID = "meeting_id"
        case createdAt = "created_at"
    }
}

public struct GlossaryMutationRequest: Codable, Equatable, Sendable {
    public let phrase: String
    public let displayAs: String?
    public let language: String

    public init(phrase: String, displayAs: String? = nil, language: String) {
        self.phrase = phrase
        self.displayAs = displayAs
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case phrase
        case displayAs
        case language = "lang"
    }
}

public struct RevealRequest: Codable, Equatable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

public struct CreatedIDResponse: Codable, Equatable, Sendable {
    public let id: Int
}
