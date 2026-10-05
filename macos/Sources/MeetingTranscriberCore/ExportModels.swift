import Foundation

package struct MeetingExportRequestScope: Sendable {
    package struct Request: Equatable, Sendable {
        package let meetingID: Int
        fileprivate let generation: UInt64
    }

    private var selectedMeetingID: Int?
    private var generation: UInt64 = 0

    package init() {}

    @discardableResult
    package mutating func selectMeeting(_ meetingID: Int?) -> Bool {
        guard selectedMeetingID != meetingID else { return false }
        selectedMeetingID = meetingID
        generation &+= 1
        return true
    }

    package mutating func begin(for loadedMeetingID: Int?) -> Request? {
        guard let loadedMeetingID, loadedMeetingID == selectedMeetingID else { return nil }
        generation &+= 1
        return Request(meetingID: loadedMeetingID, generation: generation)
    }

    package func isCurrent(_ request: Request) -> Bool {
        request.meetingID == selectedMeetingID && request.generation == generation
    }
}

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
