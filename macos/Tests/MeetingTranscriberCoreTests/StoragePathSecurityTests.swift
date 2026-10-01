import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Configured storage path security", .serialized)
struct StoragePathSecurityTests {
    @Test("relative storage paths are rejected before settings are written")
    func relativePathsAreRejected() throws {
        let fixture = try StorageSecurityFixture()
        defer { fixture.remove() }
        let store = NativeSettingsStore(configuration: fixture.configuration)
        var request = store.initialDocument().updateRequest
        request.user.name = "Storage Tester"
        request.user.profile = "Validates absolute paths."
        request.paths.database = "relative/meetings.db"

        #expect(throws: NativeServiceError.self) {
            _ = try store.update(request, etag: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.configURL.path))
    }

    @Test("symlinked attachment root is rejected")
    func symlinkedRootIsRejected() throws {
        let fixture = try StorageSecurityFixture()
        defer { fixture.remove() }
        let store = NativeSettingsStore(configuration: fixture.configuration)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = fixture.root.appendingPathComponent("linked-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        var request = store.initialDocument().updateRequest
        request.user.name = "Storage Tester"
        request.user.profile = "Rejects symlinked roots."
        request.paths.files = link.path

        #expect(throws: NativeServiceError.self) {
            _ = try store.update(request, etag: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.configURL.path))
    }

    @Test("symlinked database files are rejected before settings are written")
    func symlinkedDatabaseIsRejected() throws {
        let fixture = try StorageSecurityFixture()
        defer { fixture.remove() }
        let store = NativeSettingsStore(configuration: fixture.configuration)
        let outside = fixture.root.appendingPathComponent("outside.sqlite")
        try Data().write(to: outside)
        let link = fixture.root.appendingPathComponent("linked.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        var request = store.initialDocument().updateRequest
        request.user.name = "Storage Tester"
        request.user.profile = "Rejects symlinked databases."
        request.paths.database = link.path

        #expect(throws: NativeServiceError.self) {
            _ = try store.update(request, etag: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.configURL.path))
    }

    @Test("reveal rejects a symlinked export path that resolves outside the export root")
    func revealRejectsSymlinkEscape() async throws {
        let fixture = try StorageSecurityFixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        var request = try await service.settings().document.updateRequest
        request.user.name = "Storage Tester"
        request.user.profile = "Validates reveal containment."
        _ = try await service.updateSettings(request, etag: nil)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Reveal containment"))
        let exported = try await service.exportMeeting(id: meeting.id)
        let exportBase = URL(fileURLWithPath: exported.path, isDirectory: true)
            .deletingLastPathComponent()
        let outside = fixture.root.appendingPathComponent("outside-reveal", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = exportBase.appendingPathComponent("reveal-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: link) }

        await #expect(throws: NativeServiceError.self) {
            _ = try await service.reveal(path: link.path)
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
        await service.shutdown()
    }

    @Test("configured roots and persistent files use private modes")
    func persistentModesArePrivate() async throws {
        let fixture = try StorageSecurityFixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        var request = try await service.settings().document.updateRequest
        request.user.name = "Storage Tester"
        request.user.profile = "Validates private modes."
        let saved = try await service.updateSettings(request, etag: nil)

        let directories = [
            fixture.configURL.deletingLastPathComponent(),
            URL(fileURLWithPath: saved.document.paths.files, isDirectory: true),
            URL(fileURLWithPath: saved.document.paths.database).deletingLastPathComponent(),
        ]
        for directory in directories {
            #expect(fixture.permissions(directory) == 0o700)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            #expect(values.isDirectory == true)
            #expect(values.isSymbolicLink != true)
        }
        #expect(fixture.permissions(fixture.configURL) == 0o600)
        #expect(fixture.permissions(URL(fileURLWithPath: saved.document.paths.database)) == 0o600)
        await service.shutdown()
    }
}

private struct StorageSecurityFixture {
    let root: URL
    let configURL: URL
    let configuration: NativeServiceConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-security-\(UUID().uuidString)", isDirectory: true)
        configURL = root.appendingPathComponent("config/config.json")
        configuration = NativeServiceConfiguration(
            configURL: configURL,
            defaultDataRoot: root,
            environment: [
                "WHEREWE_SUPPRESS_OPEN": "1",
            ]
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func permissions(_ url: URL) -> Int? {
        let value = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return (value as? NSNumber)?.intValue
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
