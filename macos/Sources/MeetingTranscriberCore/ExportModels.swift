import Foundation

public struct ExportFiles: Codable, Equatable, Sendable {
    public let metadata: String
    public let transcript: String
    public let background: String
    public let attachments: [String]
}

public struct ExportCounts: Codable, Equatable, Sendable {
    public let transcripts: Int
    public let segments: Int
    public let documents: Int
    public let glossary: Int
}

public struct MeetingExportResponse: Codable, Equatable, Sendable {
    public let success: Bool
    public let path: String
    public let files: ExportFiles
    public let counts: ExportCounts
}
