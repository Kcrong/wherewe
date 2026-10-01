import Foundation

struct ResampledAudioChunk: Equatable, Sendable {
    let hostTimeNanoseconds: UInt64
    let samples: [Float]
}

final class HostTimeAudioResampler: @unchecked Sendable {
    let inputSampleRate: Double
    let outputSampleRate: Double

    private let inputIntervalNanoseconds: Double
    private let outputIntervalNanoseconds: Double
    private var nextOutputTimeNanoseconds: Double?
    private var previousSample: Float?
    private var previousSampleTimeNanoseconds: Double?

    init(inputSampleRate: Double, outputSampleRate: Double) {
        precondition(inputSampleRate.isFinite && inputSampleRate > 0)
        precondition(outputSampleRate.isFinite && outputSampleRate > 0)
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.inputIntervalNanoseconds = 1_000_000_000 / inputSampleRate
        self.outputIntervalNanoseconds = 1_000_000_000 / outputSampleRate
    }

    func process(
        samples: [Float],
        hostTimeNanoseconds: UInt64
    ) -> ResampledAudioChunk? {
        guard !samples.isEmpty else { return nil }
        guard inputSampleRate != outputSampleRate else {
            resetHistory(to: samples.last!, at: Double(hostTimeNanoseconds)
                + Double(samples.count - 1) * inputIntervalNanoseconds)
            return ResampledAudioChunk(
                hostTimeNanoseconds: hostTimeNanoseconds,
                samples: samples
            )
        }

        let startTime = Double(hostTimeNanoseconds)
        let endTime = startTime + Double(samples.count - 1) * inputIntervalNanoseconds
        if let previousTime = previousSampleTimeNanoseconds {
            let expectedStart = previousTime + inputIntervalNanoseconds
            let discontinuityThreshold = max(inputIntervalNanoseconds * 8, 10_000_000)
            if abs(startTime - expectedStart) > discontinuityThreshold {
                nextOutputTimeNanoseconds = startTime
                previousSample = nil
                previousSampleTimeNanoseconds = nil
            }
        }
        if nextOutputTimeNanoseconds == nil {
            nextOutputTimeNanoseconds = startTime
        }
        if previousSample == nil,
           let nextOutputTimeNanoseconds,
           nextOutputTimeNanoseconds < startTime {
            self.nextOutputTimeNanoseconds = startTime
        }

        var output: [Float] = []
        output.reserveCapacity(Int(ceil(Double(samples.count) * outputSampleRate / inputSampleRate)) + 1)
        var firstOutputTime: Double?
        let epsilon = inputIntervalNanoseconds / 1_000

        while let outputTime = nextOutputTimeNanoseconds,
              outputTime <= endTime + epsilon {
            let value: Float
            if outputTime < startTime,
               let previousSample,
               let previousTime = previousSampleTimeNanoseconds,
               startTime > previousTime {
                let fraction = Float((outputTime - previousTime) / (startTime - previousTime))
                value = previousSample + (samples[0] - previousSample) * fraction
            } else {
                let position = max(0, (outputTime - startTime) / inputIntervalNanoseconds)
                let lowerIndex = min(Int(floor(position)), samples.count - 1)
                let upperIndex = min(lowerIndex + 1, samples.count - 1)
                let fraction = Float(position - Double(lowerIndex))
                value = samples[lowerIndex] + (samples[upperIndex] - samples[lowerIndex]) * fraction
            }
            if firstOutputTime == nil { firstOutputTime = outputTime }
            output.append(value)
            nextOutputTimeNanoseconds = outputTime + outputIntervalNanoseconds
        }

        previousSample = samples.last
        previousSampleTimeNanoseconds = endTime
        guard let firstOutputTime, !output.isEmpty else { return nil }
        return ResampledAudioChunk(
            hostTimeNanoseconds: UInt64(max(0, firstOutputTime).rounded()),
            samples: output
        )
    }

    func reset() {
        nextOutputTimeNanoseconds = nil
        previousSample = nil
        previousSampleTimeNanoseconds = nil
    }

    private func resetHistory(to sample: Float, at timeNanoseconds: Double) {
        nextOutputTimeNanoseconds = nil
        previousSample = sample
        previousSampleTimeNanoseconds = timeNanoseconds
    }
}
