import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Native realtime isolation")
struct NativeRealtimeIsolationTests {
    @Test("retained service events reach registered clients")
    func registeredClientsReceiveEvents() async throws {
        let hub = NativeRealtimeHub()
        let first = AsyncStream.makeStream(of: RealtimeMessage.self)
        let second = AsyncStream.makeStream(of: RealtimeMessage.self)
        let firstID = UUID()
        let secondID = UUID()
        hub.register(firstID, continuation: first.continuation)
        hub.register(secondID, continuation: second.continuation)
        hub.setActive(firstID, true)
        hub.setActive(secondID, true)
        defer {
            hub.unregister(firstID)
            hub.unregister(secondID)
        }

        var firstIterator = first.stream.makeAsyncIterator()
        var secondIterator = second.stream.makeAsyncIterator()
        let payload = try JSONSerialization.data(withJSONObject: ["meetingId": 1])
        hub.publish(RealtimeMessage(name: .translationUpdated, payload: payload))

        #expect(try meetingID(try #require(await firstIterator.next())) == 1)
        #expect(try meetingID(try #require(await secondIterator.next())) == 1)
    }

    @Test("disconnect cancels audio state while preserving reconnect registration")
    func disconnectPreservesRegistration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("realtime-disconnect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = NativeRealtimeHub()
        let configuration = NativeServiceConfiguration(
            configURL: root.appendingPathComponent("config.json"),
            defaultDataRoot: root
        )
        let service = makeTestService(configuration: configuration, eventHub: hub)
        let client = NativeRealtimeClient(service: service, hub: hub)

        try await client.connect()
        #expect(hub.registrationCount() == 1)
        client.disconnect()
        #expect(hub.registrationCount() == 1)
        try await client.connect()
        #expect(hub.registrationCount() == 1)
        client.disconnect()
        await service.shutdown()
    }

    private func meetingID(_ message: RealtimeMessage) throws -> Int {
        let payload = try #require(message.payload)
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        return try #require((object["meetingId"] as? NSNumber)?.intValue)
    }
}
