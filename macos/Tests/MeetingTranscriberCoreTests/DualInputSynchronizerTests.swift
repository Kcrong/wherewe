import Testing
@testable import MeetingTranscriberCore

@Suite("Dual-input synchronization")
struct DualInputSynchronizerTests {
    private static let sampleRate = 1_000
    private static let frameSamples = 100
    private static let lagMilliseconds = 300

    @Test("a lost input is replaced with silence after the synchronization window")
    func lostInputUsesSilenceAndRecovers() throws {
        let synchronizer = try Self.synchronizer()

        #expect(try synchronizer.append(Self.chunk(.microphone, at: 0, value: 0.5)).isEmpty)
        let paired = try synchronizer.append(Self.chunk(.system, at: 0, value: 0.25))
        #expect(paired.count == 1)
        Self.expectChannels(in: paired, microphoneIsSilent: false)

        var continuedFrames: [[Int16]] = []
        for chunkIndex in 1..<10 {
            continuedFrames += try synchronizer.append(
                Self.chunk(.system, at: chunkIndex, value: 0.25)
            )
        }

        #expect(continuedFrames.count == 6)
        Self.expectChannels(in: continuedFrames, microphoneIsSilent: true)

        let catchUpFrames = try synchronizer.append(
            Self.chunk(.microphone, at: 10, value: 0.5)
        )
        #expect(catchUpFrames.count == 3)
        Self.expectChannels(in: catchUpFrames, microphoneIsSilent: true)

        let recoveredFrames = try synchronizer.append(
            Self.chunk(.system, at: 10, value: 0.25)
        )
        #expect(recoveredFrames.count == 1)
        Self.expectChannels(in: recoveredFrames, microphoneIsSilent: false)
    }

    @Test("buffering stays within the synchronization window when one input stops")
    func stalledInputBufferIsBounded() throws {
        let synchronizer = try Self.synchronizer()
        _ = try synchronizer.append(Self.chunk(.microphone, at: 0, value: 0.5))
        var emittedFrameCount = try synchronizer.append(
            Self.chunk(.system, at: 0, value: 0.25)
        ).count

        for chunkIndex in 1...100 {
            emittedFrameCount += try synchronizer.append(
                Self.chunk(.system, at: chunkIndex, value: 0.25)
            ).count
        }

        let residual = try #require(synchronizer.flush())
        let residualFrameCount = residual.count / synchronizer.channelCount
        let totalInputFrameCount = 101 * Self.frameSamples
        let maximumBufferedFrameCount = Self.sampleRate * Self.lagMilliseconds / 1_000

        #expect(residualFrameCount == maximumBufferedFrameCount)
        #expect(emittedFrameCount * Self.frameSamples + residualFrameCount == totalInputFrameCount)
    }

    private static func synchronizer() throws -> DualInputSynchronizer {
        try DualInputSynchronizer(
            sources: [.microphone, .system],
            sampleRate: sampleRate,
            frameDurationMilliseconds: 100,
            maximumSynchronizationLagMilliseconds: lagMilliseconds,
            originHostTimeNanoseconds: 0
        )
    }

    private static func chunk(
        _ source: AudioInputSource,
        at chunkIndex: Int,
        value: Float
    ) -> TimedAudioChunk {
        TimedAudioChunk(
            source: source,
            hostTimeNanoseconds: UInt64(chunkIndex) * 100_000_000,
            samples: [Float](repeating: value, count: frameSamples)
        )
    }

    private static func expectChannels(
        in frames: [[Int16]],
        microphoneIsSilent: Bool
    ) {
        for frame in frames {
            #expect(frame.count == frameSamples * 2)
            for sampleIndex in stride(from: 0, to: frame.count, by: 2) {
                #expect((frame[sampleIndex] == 0) == microphoneIsSilent)
                #expect(frame[sampleIndex + 1] > 0)
            }
        }
    }
}
