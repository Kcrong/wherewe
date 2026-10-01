import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("PCM framing")
struct PCMFramerTests {
    @Test("emits exact 100 ms mono frames at 48 kHz")
    func framesMonoAudio() throws {
        var framer = try PCMFramer(channelCount: 1)
        let samples = (0..<9_700).map { Int16(truncatingIfNeeded: $0) }

        let frames = try framer.append(samples)

        #expect(frames.count == 2)
        #expect(frames.allSatisfy { $0.count == 4_800 * 2 })
        #expect(framer.pendingSampleCount == 100)
        #expect(framer.flush()?.count == 200)
        #expect(framer.pendingSampleCount == 0)
    }

    @Test("preserves interleaved stereo sample order")
    func preservesStereoOrder() throws {
        var framer = try PCMFramer(sampleRate: 10, channelCount: 2, frameDurationMilliseconds: 100)
        let frames = try framer.append([1, -2, 3, -4])

        #expect(frames.count == 2)
        #expect(decode(frames[0]) == [1, -2])
        #expect(decode(frames[1]) == [3, -4])
        #expect(framer.flush() == nil)
    }

    @Test("rejects a partial interleaved stereo sample")
    func rejectsMisalignedStereoInput() throws {
        var framer = try PCMFramer(channelCount: 2)
        #expect(throws: PCMFramer.FramingError.misalignedSamples) {
            try framer.append([1, 2, 3])
        }
        #expect(framer.pendingSampleCount == 0)
    }

    @Test("reset drops only buffered residual audio")
    func resetsResidualAudio() throws {
        var framer = try PCMFramer(channelCount: 1)
        _ = try framer.append([1, 2, 3])
        framer.reset()

        #expect(framer.pendingSampleCount == 0)
        #expect(framer.flush() == nil)
    }

    private func decode(_ data: Data) -> [Int16] {
        stride(from: 0, to: data.count, by: 2).map { offset in
            let low = UInt16(data[offset])
            let high = UInt16(data[offset + 1]) << 8
            return Int16(bitPattern: low | high)
        }
    }
}
