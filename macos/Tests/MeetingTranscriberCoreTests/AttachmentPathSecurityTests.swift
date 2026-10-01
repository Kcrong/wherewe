import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Stored attachment path security")
struct AttachmentPathSecurityTests {
    @Test("export rejects a stored path outside the configured attachment root")
    func exportRejectsOutsidePath() async throws {
        let fixture = try AttachmentSecurityFixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Outside export"))
        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("outside test content".utf8).write(to: outside)
        _ = try await service.insertDocumentForSecurityTest(
            meetingID: meeting.id,
            name: "outside.txt",
            format: "txt",
            path: outside.path
        )

        await #expect(throws: NativeServiceError.self) {
            _ = try await service.exportMeeting(id: meeting.id)
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("export rejects an attachment symlink that escapes the configured root")
    func exportRejectsSymlinkEscape() async throws {
        let fixture = try AttachmentSecurityFixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Symlink export"))
        let outside = fixture.root.appendingPathComponent("outside-target.txt")
        try Data("outside symlink target".utf8).write(to: outside)
        let link = fixture.filesRoot.appendingPathComponent("attachment-link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        _ = try await service.insertDocumentForSecurityTest(
            meetingID: meeting.id,
            name: "attachment-link.txt",
            format: "txt",
            path: link.path
        )

        await #expect(throws: NativeServiceError.self) {
            _ = try await service.exportMeeting(id: meeting.id)
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("meeting deletion rejects an outside directory without removing the meeting")
    func meetingDeleteRejectsOutsideDirectory() async throws {
        let fixture = try AttachmentSecurityFixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Outside meeting delete"))
        let outside = fixture.root.appendingPathComponent("outside-meeting-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("must survive".utf8).write(to: outside.appendingPathComponent("sentinel.txt"))
        _ = try await service.insertDocumentForSecurityTest(
            meetingID: meeting.id,
            name: "outside-meeting-directory",
            format: "txt",
            path: outside.path
        )

        await #expect(throws: NativeServiceError.self) {
            _ = try await service.deleteMeeting(id: meeting.id, socketID: nil)
        }
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("sentinel.txt").path))
        #expect(try await service.meeting(id: meeting.id).id == meeting.id)
    }

    @Test("document deletion rejects an outside directory without removing it")
    func deleteRejectsOutsideDirectory() async throws {
        let fixture = try AttachmentSecurityFixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Outside delete"))
        let outside = fixture.root.appendingPathComponent("outside-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("must survive".utf8).write(to: outside.appendingPathComponent("sentinel.txt"))
        let documentID = try await service.insertDocumentForSecurityTest(
            meetingID: meeting.id,
            name: "outside-directory",
            format: "txt",
            path: outside.path
        )

        await #expect(throws: NativeServiceError.self) {
            _ = try await service.deleteDocument(id: documentID)
        }
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("sentinel.txt").path))
        #expect(try await service.documents(meetingID: meeting.id).map(\.id) == [documentID])
    }
}

private extension NativeService {
    func insertDocumentForSecurityTest(
        meetingID: Int,
        name: String,
        format: String,
        path: String
    ) throws -> Int {
        let result = try requireDatabase().run(
            "INSERT INTO documents (meeting_id, name, format, file_path) VALUES (?, ?, ?, ?)",
            [.integer(Int64(meetingID)), .text(name), .text(format), .text(path)]
        )
        return result.lastInsertID
    }
}

private struct AttachmentSecurityFixture {
    let root: URL
    let configuration: NativeServiceConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-security-\(UUID().uuidString)", isDirectory: true)
        configuration = NativeServiceConfiguration(
            configURL: root.appendingPathComponent("config.json"),
            defaultDataRoot: root,
            environment: [
                "WHEREWE_SUPPRESS_OPEN": "1",
            ]
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var filesRoot: URL {
        root.appendingPathComponent("data/files", isDirectory: true)
    }

    func configure(_ service: NativeService) async throws {
        var request = try await service.settings().document.updateRequest
        request.user.name = "Security Tester"
        request.user.profile = "Validates stored attachment paths."
        _ = try await service.updateSettings(request, etag: nil)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
