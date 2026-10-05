import Foundation
import MeetingTranscriberCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private struct CheckRunner {
    private(set) var count = 0

    mutating func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(description: message) }
        count += 1
    }
}

@main
private enum MeetingTranscriberCoreChecks {
    static func main() async throws {
        var checks = CheckRunner()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("wherewe-core-checks-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let service = NativeService(configuration: NativeServiceConfiguration(
            configURL: root.appendingPathComponent("config.json"),
            defaultDataRoot: root,
            applicationVersion: "checks",
            environment: ["WHEREWE_SUPPRESS_OPEN": "1"]
        ))

        let setupHealth = try await service.health()
        try checks.expect(setupHealth.state == .setupRequired, "new service did not require setup")

        var request = try await service.settings().document.updateRequest
        request.user.name = "Core Checks"
        request.user.profile = "Exercises the Apple-only native core."
        request.transcription.engine = "retired"
        request.transcription.local.provider = "retired"
        request.transcription.local.model = "retired"
        request.translation.provider = "retired"
        let saved = try await service.updateSettings(request, etag: nil)
        try checks.expect(saved.document.transcription.engine == "apple", "transcription engine was not normalized")
        try checks.expect(saved.document.transcription.local.provider == "apple", "transcription provider was not normalized")
        try checks.expect(saved.document.transcription.local.model == "system", "transcription model was not normalized")
        try checks.expect(saved.document.translation.provider == "apple", "translation provider was not normalized")

        let catalogue = try await service.transcriptionCatalogue(language: "en-US")
        try checks.expect(catalogue.localProviders.map(\.id) == ["apple"], "catalogue exposed a non-Apple provider")

        let created = try await service.createMeeting(CreateMeetingRequest(
            title: "Apple core validation",
            context: "Validate retained local capabilities.",
            language: "en-US",
            translationTarget: "ko"
        ))
        let document = try await service.uploadDocument(
            meetingID: created.id,
            name: "context.txt",
            data: Data("Local context".utf8)
        )
        let glossary = try await service.createGlossary(GlossaryMutationRequest(
            phrase: "release gate",
            displayAs: "release gate",
            language: "en"
        ))

        let detail = try await service.meeting(id: created.id)
        try checks.expect(detail.title == "Apple core validation", "meeting title did not persist")
        try checks.expect(detail.context == "Validate retained local capabilities.", "meeting context did not persist")
        try checks.expect(detail.documents.count == 1, "meeting attachment did not persist")
        let glossaryRows = try await service.glossary(language: "en")
        try checks.expect(glossaryRows.count == 1, "glossary entry did not persist")

        let exported = try await service.exportMeeting(id: created.id)
        let exportRoot = URL(fileURLWithPath: exported.path, isDirectory: true)
        try checks.expect(fileManager.fileExists(atPath: exportRoot.appendingPathComponent(exported.files.metadata).path), "metadata export is missing")
        try checks.expect(fileManager.fileExists(atPath: exportRoot.appendingPathComponent(exported.files.transcript).path), "transcript export is missing")
        let backgroundURL = exportRoot.appendingPathComponent(exported.files.background)
        try checks.expect(fileManager.fileExists(atPath: backgroundURL.path), "background export is missing")
        let background = String(decoding: try Data(contentsOf: backgroundURL), as: UTF8.self)
        try checks.expect(exported.counts.documents == 1, "export document count drifted")
        try checks.expect(exported.counts.glossary == 1, "matching global glossary term was omitted from export")
        try checks.expect(background.contains("**release gate** → release gate _[en]_"), "global glossary term is missing from context")

        _ = try await service.deleteDocument(id: document.id)
        _ = try await service.deleteGlossary(id: glossary.id)
        _ = try await service.deleteMeeting(id: created.id, socketID: nil)
        let remainingMeetings = try await service.meetings()
        try checks.expect(remainingMeetings.isEmpty, "meeting deletion did not persist")

        await service.shutdown()
        print("MeetingTranscriberCoreChecks passed \(checks.count) checks")
    }
}
