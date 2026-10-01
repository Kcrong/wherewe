import CoreAudio
import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Native physical audio", .serialized)
struct NativePhysicalAudioTests {
    @Test("BlackHole fixture persists speech and filters muted microphone noise", .enabled(if: NativeRuntimeEvidence.isRequested("WHEREWE_NATIVE_REAL_HARDWARE"), "Set WHEREWE_NATIVE_REAL_HARDWARE=1 on a prepared physical Mac to run."))
    func blackHoleRecording() async throws {
        let devices = try CoreAudioDeviceCatalog().inputDevices()
        let microphone = try #require(devices.first(where: { $0.isDefaultInput }))
        let blackHole = try #require(devices.first(where: { $0.name.localizedCaseInsensitiveContains("BlackHole") }))
        #expect(try defaultOutputName() == blackHole.name)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-physical-audio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = NativeServiceConfiguration(
            configURL: root.appendingPathComponent("config.json"),
            defaultDataRoot: root,
            applicationVersion: "hardware-test",
            environment: ["WHEREWE_SUPPRESS_OPEN": "1"]
        )
        let service = NativeService(
            configuration: configuration,
            speechService: NativeAppleSpeechService(),
            translationService: DeterministicTranslationService()
        )
        var settings = try await service.settings().document.updateRequest
        settings.user.name = "Hardware Test"
        settings.user.profile = "Physical BlackHole validation"
        settings.transcription.local = LocalTranscriptionSettings(
            provider: "apple",
            model: "system",
            apple: AppleSpeechSettings(mode: "live", showDetails: true)
        )
        _ = try await service.updateSettings(settings, etag: nil)
        let meeting = try await service.createMeeting(CreateMeetingRequest(
            title: "Physical native audio",
            language: "en-US",
            translationTarget: "ko"
        ))
        let realtime = NativeRealtimeClient(service: service)
        let coordinator = RecordingCoordinator(api: service, realtime: realtime, readyTimeout: .seconds(30))
        let capture = CoreAudioCaptureSession()
        let pump = Task { () throws -> Void in
            for await event in capture.frames {
                switch event {
                case let .frame(samples): try await coordinator.sendPCM(samples)
                case .drained: return
                }
            }
        }

        _ = try await coordinator.start(
            meetingID: meeting.id,
            language: "en-US",
            translationTarget: "ko",
            channelCount: 2
        )
        #expect(try await capture.start(
            microphone: microphone,
            systemInput: blackHole,
            microphoneMuted: true
        ) == 2)

        let generated = try SyntheticSpeechFixture.make()
        defer { generated.remove() }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [generated.url.path]
        try player.run()
        player.waitUntilExit()
        #expect(player.terminationStatus == 0)
        try await Task.sleep(for: .milliseconds(500))
        _ = await capture.stop()
        try await pump.value
        let outcome = try await coordinator.stop()
        #expect(outcome.audioDeliveryConfirmed)

        let detail = try await service.meeting(id: meeting.id)
        #expect(detail.transcripts.count == 1)
        #expect(detail.transcripts[0].channelID == "ch_1")
        #expect(detail.transcripts[0].text.localizedCaseInsensitiveContains("transcription system"))
        #expect(detail.transcripts[0].translationStatus == .succeeded)
        #expect(!detail.transcripts.contains { NativeTranscriptNoise.isLikelyNoise($0.text) })
        await coordinator.close()
        await service.shutdown()
        NativeRuntimeEvidence.record("physical-dual-input")
    }

    @Test("BlackHole system-only fixture transcribes as one channel without microphone consent", .enabled(if: NativeRuntimeEvidence.isRequested("WHEREWE_NATIVE_REAL_HARDWARE"), "Set WHEREWE_NATIVE_REAL_HARDWARE=1 on a prepared physical Mac to run."))
    func blackHoleSystemOnlyRecording() async throws {
        let devices = try CoreAudioDeviceCatalog().inputDevices()
        let blackHole = try #require(devices.first(where: { $0.name.localizedCaseInsensitiveContains("BlackHole") }))
        #expect(try defaultOutputName() == blackHole.name)
        #expect(!CoreAudioCaptureSession.requiresRecordingPermission(microphone: nil))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-system-audio-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = NativeServiceConfiguration(
            configURL: root.appendingPathComponent("config.json"),
            defaultDataRoot: root,
            applicationVersion: "system-audio-test",
            environment: ["WHEREWE_SUPPRESS_OPEN": "1"]
        )
        let service = NativeService(
            configuration: configuration,
            speechService: NativeAppleSpeechService(),
            translationService: DeterministicTranslationService()
        )
        var settings = try await service.settings().document.updateRequest
        settings.user.name = "System Audio Test"
        settings.user.profile = "One-channel BlackHole validation"
        settings.transcription.local = LocalTranscriptionSettings(
            provider: "apple",
            model: "system",
            apple: AppleSpeechSettings(mode: "live", showDetails: true)
        )
        _ = try await service.updateSettings(settings, etag: nil)
        let meeting = try await service.createMeeting(CreateMeetingRequest(
            title: "System-only physical audio",
            language: "en-US",
            translationTarget: "ko"
        ))
        let realtime = NativeRealtimeClient(service: service)
        let coordinator = RecordingCoordinator(api: service, realtime: realtime, readyTimeout: .seconds(30))
        let capture = CoreAudioCaptureSession()
        let pump = Task { () throws -> Void in
            for await event in capture.frames {
                switch event {
                case let .frame(samples): try await coordinator.sendPCM(samples)
                case .drained: return
                }
            }
        }

        _ = try await coordinator.start(
            meetingID: meeting.id,
            language: "en-US",
            translationTarget: "ko",
            channelCount: 1
        )
        #expect(try await capture.start(
            microphone: nil,
            systemInput: blackHole,
            microphoneMuted: true
        ) == 1)

        let generated = try SyntheticSpeechFixture.make()
        defer { generated.remove() }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [generated.url.path]
        try player.run()
        player.waitUntilExit()
        #expect(player.terminationStatus == 0)
        try await Task.sleep(for: .milliseconds(500))
        _ = await capture.stop()
        try await pump.value
        let outcome = try await coordinator.stop()
        #expect(outcome.audioDeliveryConfirmed)

        let detail = try await service.meeting(id: meeting.id)
        #expect(detail.transcripts.count == 1)
        #expect(detail.transcripts[0].channelID == nil)
        #expect(detail.transcripts[0].text.localizedCaseInsensitiveContains("transcription system"))
        #expect(detail.transcripts[0].text.localizedCaseInsensitiveContains("hear me clearly"))
        #expect(detail.transcripts[0].translationStatus == .succeeded)
        await coordinator.close()
        await service.shutdown()
        NativeRuntimeEvidence.record("physical-system-only")
    }

    private func defaultOutputName() throws -> String {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress, 0, nil, &size, &device
        ) == noErr else { throw PhysicalAudioError.defaultOutput }
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &size, &value) == noErr,
              let value else { throw PhysicalAudioError.defaultOutput }
        return value.takeUnretainedValue() as String
    }
}

private enum PhysicalAudioError: Error {
    case defaultOutput
}
