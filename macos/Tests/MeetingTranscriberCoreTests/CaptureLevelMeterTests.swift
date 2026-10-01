import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Capture level meter")
struct CaptureLevelMeterTests {
    @Test("silence reads as zero and full scale as one")
    func levelMapping() {
        #expect(CaptureLevelMeter.level(meanSquare: 0) == 0)
        #expect(CaptureLevelMeter.level(meanSquare: 1) == 1)
        // -30 dBFS sits halfway across the -60…0 range.
        #expect(abs(CaptureLevelMeter.level(meanSquare: pow(10, -3)) - 0.5) < 1e-9)
        #expect(CaptureLevelMeter.level(meanSquare: pow(10, -8)) == 0)
    }

    @Test("a level is reported once per window, not per frame")
    func reportsPerWindow() {
        var meter = CaptureLevelMeter(channelCount: 1, sampleRate: 1_000, windowSeconds: 0.1)
        #expect(meter.consume(Array(repeating: 1_000, count: 50)) == nil)
        let levels = meter.consume(Array(repeating: 1_000, count: 50))
        #expect(levels?.count == 1)
        #expect(meter.consume(Array(repeating: 1_000, count: 99)) == nil)
    }

    @Test("stereo channels are measured independently")
    func stereoChannelsAreIndependent() throws {
        var meter = CaptureLevelMeter(channelCount: 2, sampleRate: 1_000, windowSeconds: 0.1)
        var interleaved: [Int16] = []
        for _ in 0..<100 { interleaved += [0, 16_000] }  // muted mic, active system audio

        let measured = meter.consume(interleaved)
        let levels = try #require(measured)

        #expect(levels[0] == 0)
        #expect(levels[1] > 0.8)
    }

    @Test("real speech registers clearly above silence")
    func realSpeechRegisters() throws {
        let generated = try SyntheticSpeechFixture.make()
        defer { generated.remove() }
        let wav = generated.wav
        let samples = wav.pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        var meter = CaptureLevelMeter(channelCount: 1, sampleRate: wav.sampleRate)
        var peak = 0.0
        for start in stride(from: 0, to: samples.count, by: 1_600) {
            let chunk = Array(samples[start..<min(samples.count, start + 1_600)])
            if let level = meter.consume(chunk)?.first { peak = max(peak, level) }
        }
        #expect(peak > 0.5, "peak level \(peak)")
    }
}
