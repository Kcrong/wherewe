import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Export failure and cancellation", .serialized)
struct ExportFailureSecurityTests {
    @Test("write collision removes the partial export bundle")
    func writeCollisionRollsBack() async throws {
        let fixture = try ExportFailureFixture()
        defer { fixture.remove() }
        let gate = ExportSuspensionGate()
        let service = makeTestService(configuration: fixture.configuration)
        await service.setExportLifecycleObserver(NativeExportLifecycleObserver(
            afterDirectoryCreation: { await gate.pause(exportURL: $0) }
        ))
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Write failure"))

        let task = Task { try await service.exportMeeting(id: meeting.id) }
        let exportURL = await gate.waitUntilPaused()
        try Data("collision".utf8).write(
            to: exportURL.appendingPathComponent("meeting.json"),
            options: .withoutOverwriting
        )
        await gate.release()

        do {
            _ = try await task.value
            Issue.record("Export unexpectedly replaced a colliding destination file.")
        } catch {}
        #expect(!FileManager.default.fileExists(atPath: exportURL.path))
        await service.shutdown()
    }

    @Test("cancellation removes the partial export bundle")
    func cancellationRollsBack() async throws {
        let fixture = try ExportFailureFixture()
        defer { fixture.remove() }
        let gate = ExportSuspensionGate()
        let service = makeTestService(configuration: fixture.configuration)
        await service.setExportLifecycleObserver(NativeExportLifecycleObserver(
            afterDirectoryCreation: { await gate.pause(exportURL: $0) }
        ))
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Cancelled export"))

        let task = Task { try await service.exportMeeting(id: meeting.id) }
        let exportURL = await gate.waitUntilPaused()
        task.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: exportURL.path))
        await service.shutdown()
    }
}

private actor ExportSuspensionGate {
    private var exportURL: URL?
    private var entryWaiters: [CheckedContinuation<URL, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause(exportURL: URL) async {
        self.exportURL = exportURL
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        waitingForEntry.forEach { $0.resume(returning: exportURL) }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilPaused() async -> URL {
        if let exportURL { return exportURL }
        return await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }
}

private struct ExportFailureFixture {
    let root: URL
    let configuration: NativeServiceConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-failure-\(UUID().uuidString)", isDirectory: true)
        configuration = NativeServiceConfiguration(
            configURL: root.appendingPathComponent("config.json"),
            defaultDataRoot: root,
            environment: [
                "WHEREWE_SUPPRESS_OPEN": "1",
            ]
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func configure(_ service: NativeService) async throws {
        var request = try await service.settings().document.updateRequest
        request.user.name = "Export Failure Tester"
        request.user.profile = "Validates fail-closed export rollback."
        _ = try await service.updateSettings(request, etag: nil)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
