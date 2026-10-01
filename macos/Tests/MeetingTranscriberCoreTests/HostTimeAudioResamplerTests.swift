import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Host-time audio resampling")
struct HostTimeAudioResamplerTests {
    @Test("48 kHz input is preserved byte-for-byte")
    func preservesMatchingRate() {
        let resampler = HostTimeAudioResampler(
            inputSampleRate: 48_000,
            outputSampleRate: 48_000
        )
        let samples: [Float] = [-1, -0.25, 0, 0.5, 1]

        let output = resampler.process(
            samples: samples,
            hostTimeNanoseconds: 123_456_789
        )

        #expect(output == ResampledAudioChunk(
            hostTimeNanoseconds: 123_456_789,
            samples: samples
        ))
    }

    @Test("44.1 kHz chunks form one continuous 48 kHz timeline")
    func upsamplesContinuousChunks() throws {
        let resampler = HostTimeAudioResampler(
            inputSampleRate: 44_100,
            outputSampleRate: 48_000
        )
        let origin: UInt64 = 1_000_000_000
        var outputs: [ResampledAudioChunk] = []

        for chunkIndex in 0..<100 {
            let samples = (0..<441).map { index in
                Float(sin(Double(chunkIndex * 441 + index) / 37))
            }
            if let output = resampler.process(
                samples: samples,
                hostTimeNanoseconds: origin + UInt64(chunkIndex * 10_000_000)
            ) {
                outputs.append(output)
            }
        }

        let sampleCount = outputs.reduce(0) { $0 + $1.samples.count }
        #expect((47_999...48_000).contains(sampleCount))
        #expect(outputs.allSatisfy { $0.samples.allSatisfy(\.isFinite) })
        try expectContinuousHostTimes(outputs)
    }

    @Test("96 kHz input downsamples to 48 kHz without chunk-boundary drift")
    func downsamplesContinuousChunks() throws {
        let resampler = HostTimeAudioResampler(
            inputSampleRate: 96_000,
            outputSampleRate: 48_000
        )
        let first = (0..<960).map { Float($0) / 1_920 }
        let second = (960..<1_920).map { Float($0) / 1_920 }

        let outputA = try #require(resampler.process(
            samples: first,
            hostTimeNanoseconds: 2_000_000_000
        ))
        let outputB = try #require(resampler.process(
            samples: second,
            hostTimeNanoseconds: 2_010_000_000
        ))

        #expect(outputA.samples.count + outputB.samples.count == 960)
        #expect(abs(outputA.samples[1] - first[2]) < 0.000_001)
        #expect(abs(outputB.samples[0] - second[0]) < 0.000_001)
        try expectContinuousHostTimes([outputA, outputB])
    }

    private func expectContinuousHostTimes(
        _ outputs: [ResampledAudioChunk]
    ) throws {
        let interval = 1_000_000_000 / 48_000.0
        for pair in zip(outputs, outputs.dropFirst()) {
            let expected = Double(pair.0.hostTimeNanoseconds)
                + Double(pair.0.samples.count) * interval
            #expect(abs(Double(pair.1.hostTimeNanoseconds) - expected) <= 2)
        }
    }
}
