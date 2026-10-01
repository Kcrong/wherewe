import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Live native service contract")
struct LiveNativeServiceContractTests {
    @Test("isolated service starts in setup-required state without a child process")
    func isolatedNativeHealth() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-native-contract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = NativeService(configuration: NativeServiceConfiguration(
            configURL: root.appendingPathComponent("config.json"),
            defaultDataRoot: root,
            applicationVersion: "test"
        ))

        let health = try await service.health()
        #expect(health.state == .setupRequired)
        #expect(!health.configured)
        #expect(!health.realtimeAvailable)
    }
}
