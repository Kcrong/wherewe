import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Native service contracts")
struct ModelsTests {
    @Test("configured health decodes and validates")
    func configuredHealthDecodesAndValidates() throws {
        let data = Data(#"{"service":"wherewe","applicationVersion":"1.0.0","protocolVersion":1,"state":"ready","configured":true,"setupRequired":false,"realtimeAvailable":true}"#.utf8)
        let health = try JSONDecoder().decode(NativeServiceHealth.self, from: data)

        try health.validateCompatibility()
        #expect(health.state == .ready)
    }

    @Test("setup health decodes and validates")
    func setupHealthDecodesAndValidates() throws {
        let data = Data(#"{"service":"wherewe","applicationVersion":"1.0.0","protocolVersion":1,"state":"setup-required","configured":false,"setupRequired":true,"realtimeAvailable":false}"#.utf8)
        let health = try JSONDecoder().decode(NativeServiceHealth.self, from: data)

        try health.validateCompatibility()
        #expect(health.state == .setupRequired)
    }

    @Test("health rejects protocol and state drift")
    func healthRejectsProtocolAndStateDrift() {
        let wrongProtocol = NativeServiceHealth(
            service: NativeProtocol.service,
            applicationVersion: "1.0.0",
            protocolVersion: 2,
            state: .ready,
            configured: true,
            setupRequired: false,
            realtimeAvailable: true
        )
        #expect(throws: NativeServiceContractError.incompatibleProtocol(expected: 1, actual: 2)) {
            try wrongProtocol.validateCompatibility()
        }

        let inconsistent = NativeServiceHealth(
            service: NativeProtocol.service,
            applicationVersion: "1.0.0",
            protocolVersion: 1,
            state: .ready,
            configured: false,
            setupRequired: true,
            realtimeAvailable: false
        )
        #expect(throws: NativeServiceContractError.inconsistentHealth) {
            try inconsistent.validateCompatibility()
        }
    }

    @Test("meeting selection admits mutations only after the matching load")
    func meetingSelectionRequiresMatchingLoad() {
        var selection = MeetingSelectionState()

        #expect(selection.select(11))
        #expect(selection.beginLoading() == 11)
        #expect(selection.mutationID == nil)
        #expect(selection.finishLoading(11))
        #expect(selection.mutationID == 11)

        #expect(selection.select(22))
        #expect(selection.loadedID == nil)
        #expect(selection.mutationID == nil)
        #expect(!selection.finishLoading(11))
        #expect(selection.mutationID == nil)
        #expect(selection.finishLoading(22))
        #expect(selection.mutationID == 22)

        #expect(!selection.select(22))
        #expect(selection.mutationID == 22)
    }

    @Test("meeting list tolerates omitted optional fields")
    func meetingListDecodesSnakeCaseWithoutRequiringOptionalFields() throws {
        let data = Data(#"[{"id":7,"title":"Design review","created_at":"2026-09-23 01:00:00"},{"id":8,"title":"Practice"}]"#.utf8)
        let meetings = try JSONDecoder().decode([MeetingSummary].self, from: data)

        #expect(meetings.count == 2)
        #expect(meetings[0].createdAt == "2026-09-23 01:00:00")
        #expect(meetings[1].createdAt == nil)
    }
}
