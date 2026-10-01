import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Clean-install capture regressions")
struct CaptureRegressionTests {
    // MARK: Commit boundaries

    @Test("a commit never splits speech that starts after a pause")
    func commitCutsInPauseBeforeSpeech() throws {
        // Reproduces the clean-install split: the ten-second commit point
        // fell inside "clearly", leaving a separate "Yearly?" line.
        let generated = try SyntheticSpeechFixture.make()
        defer { generated.remove() }
        let wav = generated.wav
        let silenceSeconds = 6.4
        let buffer = Self.silence(seconds: silenceSeconds, rate: wav.sampleRate) + wav.pcm
        let committed = buffer.prefix(Int(wav.sampleRate) * 2 * 10)

        let length = PCMCommitBoundary.commitLength(
            of: committed,
            channelCount: 1,
            sampleRate: wav.sampleRate
        )

        let cutSeconds = Double(length / 2) / wav.sampleRate
        #expect(cutSeconds >= 6)
        #expect(cutSeconds < silenceSeconds, "cut at \(cutSeconds)s is inside the speech")
    }

    @Test("a commit inside continuous speech lands in its quietest gap")
    func commitCutsAtQuietGapInsideSpeech() throws {
        let generated = try SyntheticSpeechFixture.make()
        defer { generated.remove() }
        let wav = generated.wav
        let buffer = wav.pcm + wav.pcm + wav.pcm
        let length = PCMCommitBoundary.commitLength(of: buffer, channelCount: 1, sampleRate: wav.sampleRate)

        let rate = Int(wav.sampleRate)
        let cutFrame = length / 2
        #expect(cutFrame >= rate * 6 && cutFrame <= buffer.count / 2)
        let around = Self.rms(buffer, frames: (cutFrame - rate / 20)..<(cutFrame + rate / 20))
        let overall = Self.rms(buffer, frames: 0..<(buffer.count / 2))
        #expect(around < overall * 0.1, "cut RMS \(around) is not a pause (overall \(overall))")
    }

    @Test("a quiet gap must be quiet on every channel")
    func stereoCutRequiresSilenceOnBothChannels() {
        let rate = 16_000.0
        let frames = Int(rate) * 10
        var samples = [Int16](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let seconds = Double(frame) / rate
            let tone = Int16(8_000 * sin(2 * .pi * 220 * seconds))
            // Channel 0 pauses at 7.0-7.3 s; channel 1 pauses at 8.0-8.3 s
            // and again at 9.0-9.3 s, where channel 0 is silent too.
            let left = (7.0..<7.3).contains(seconds) || (9.0..<9.3).contains(seconds) ? 0 : tone
            let right = (8.0..<8.3).contains(seconds) || (9.0..<9.3).contains(seconds) ? 0 : tone
            samples[frame * 2] = left
            samples[frame * 2 + 1] = right
        }
        let data = samples.withUnsafeBytes { Data($0) }

        let length = PCMCommitBoundary.commitLength(of: data, channelCount: 2, sampleRate: rate)

        #expect(length.isMultiple(of: 4))
        let cutSeconds = Double(length / 4) / rate
        #expect((9.0..<9.3).contains(cutSeconds), "cut at \(cutSeconds)s")
    }

    @Test("short or finishing chunks are committed whole")
    func shortChunksCommitWhole() {
        let data = Self.silence(seconds: 5, rate: 16_000)
        #expect(PCMCommitBoundary.commitLength(of: data, channelCount: 1, sampleRate: 16_000) == data.count)
        #expect(PCMCommitBoundary.commitLength(of: Data(), channelCount: 2, sampleRate: 48_000) == 0)
    }

    // MARK: CoreAudio start deadline

    @Test("a wedged CoreAudio start releases the caller and is abandoned later")
    func wedgedStartTimesOut() async throws {
        let release = DispatchSemaphore(value: 0)
        let abandoned = Flag()
        let clock = ContinuousClock()

        await #expect(throws: CoreAudioCaptureError.startTimedOut) {
            try await CoreAudioStartDeadline.run(
                timeout: 0.2,
                work: { release.wait() },
                abandon: { abandoned.set() }
            )
        }
        #expect(!abandoned.value)

        release.signal()
        let deadline = clock.now + .seconds(2)
        while !abandoned.value, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abandoned.value)
    }

    @Test("a prompt CoreAudio start succeeds and is not abandoned")
    func promptStartSucceeds() async throws {
        let abandoned = Flag()
        try await CoreAudioStartDeadline.run(timeout: 2, work: {}, abandon: { abandoned.set() })
        try await Task.sleep(for: .milliseconds(50))
        #expect(!abandoned.value)
    }

    @Test("a failing CoreAudio start reports its own error")
    func failingStartPropagates() async {
        await #expect(throws: CoreAudioCaptureError.start(-50)) {
            try await CoreAudioStartDeadline.run(
                timeout: 2,
                work: { throw CoreAudioCaptureError.start(-50) },
                abandon: {}
            )
        }
    }

    // MARK: Voice-processing policy

    @Test("voice processing is off when the default output is a captured loopback")
    func loopbackDisablesVoiceProcessing() {
        let mic = Self.device(id: 10, isDefaultInput: true)
        let blackHole = Self.device(id: 20, isDefaultInput: false)
        #expect(!CoreAudioCaptureSession.voiceProcessingAllowed(
            systemInput: blackHole, microphone: mic, defaultOutputID: 20
        ))
        #expect(CoreAudioCaptureSession.voiceProcessingAllowed(
            systemInput: blackHole, microphone: mic, defaultOutputID: 30
        ))
        #expect(CoreAudioCaptureSession.voiceProcessingAllowed(
            systemInput: nil, microphone: mic, defaultOutputID: nil
        ))
        #expect(!CoreAudioInputStream.shouldUseVoiceProcessingIO(
            processingMode: .voiceProcessedMicrophone,
            isDefaultInput: true,
            voiceProcessingAllowed: false
        ))
    }

    @Test("system-only capture does not request unused microphone permission")
    func systemOnlySkipsMicrophonePermission() {
        let microphone = Self.device(id: 10, isDefaultInput: true)
        #expect(CoreAudioCaptureSession.requiresRecordingPermission(microphone: microphone))
        #expect(!CoreAudioCaptureSession.requiresRecordingPermission(microphone: nil))
    }

    // MARK: Process-owned spools

    @Test("spool workspace and PCM files enforce private modes")
    func spoolWorkspaceModes() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("spool-workspace-\(UUID().uuidString)", isDirectory: true)
        let workspace = try NativeSpoolWorkspace(baseURL: base)
        defer {
            workspace.close()
            try? FileManager.default.removeItem(at: base)
        }

        let spool = try workspace.makeSpoolFile()
        defer { try? spool.handle.close() }

        #expect(spool.url.deletingLastPathComponent() == workspace.directory)
        #expect(Self.permissions(workspace.directory) == 0o700)
        #expect(Self.permissions(spool.url) == 0o600)
    }

    @Test("sweeper preserves a live process workspace and removes it after exit")
    func liveProcessWorkspaceIsNotSwept() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("spool-live-owner-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        owner.arguments = ["30"]
        try owner.run()
        defer {
            if owner.isRunning {
                owner.terminate()
                owner.waitUntilExit()
            }
        }
        let workspace = base.appendingPathComponent(
            "process-\(owner.processIdentifier)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.path)
        let lock = workspace.appendingPathComponent(".owner.lock")
        #expect(fileManager.createFile(
            atPath: lock.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ))
        let spool = workspace.appendingPathComponent("active.pcm")
        #expect(fileManager.createFile(
            atPath: spool.path,
            contents: Data([1, 0]),
            attributes: [.posixPermissions: 0o600]
        ))

        let liveSweep = NativeSpoolWorkspace.sweepStaleWorkspaces(
            in: base,
            fileManager: fileManager
        )
        #expect(!liveSweep.contains(workspace))
        #expect(fileManager.fileExists(atPath: spool.path))

        owner.terminate()
        owner.waitUntilExit()
        let deadSweep = NativeSpoolWorkspace.sweepStaleWorkspaces(
            in: base,
            fileManager: fileManager
        )
        #expect(deadSweep.map(\.lastPathComponent).contains(workspace.lastPathComponent))
        #expect(!fileManager.fileExists(atPath: workspace.path))
    }

    // MARK: Helpers

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var value: Bool { lock.withLock { raised } }
        func set() { lock.withLock { raised = true } }
    }

    private static func permissions(_ url: URL) -> Int? {
        let value = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return (value as? NSNumber)?.intValue
    }

    static func silence(seconds: Double, rate: Double) -> Data {
        Data(count: Int(seconds * rate) * 2)
    }

    private static func rms(_ pcm: Data, frames: Range<Int>) -> Double {
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let sum = frames.reduce(0.0) { total, index in
                let value = Double(Int16(littleEndian: samples[index]))
                return total + value * value
            }
            return (sum / Double(frames.count)).squareRoot()
        }
    }

    private static func device(id: UInt32, isDefaultInput: Bool) -> AudioInputDevice {
        AudioInputDevice(
            id: id,
            uid: "device-\(id)",
            name: "Device \(id)",
            inputChannelCount: 2,
            nominalSampleRate: 48_000,
            isDefaultInput: isDefaultInput
        )
    }
}
