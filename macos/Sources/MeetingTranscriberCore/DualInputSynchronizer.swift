import Foundation

public enum AudioInputSource: String, CaseIterable, Sendable {
    case microphone
    case system
}

public struct TimedAudioChunk: Sendable {
    public let source: AudioInputSource
    public let hostTimeNanoseconds: UInt64
    public let samples: [Float]

    public init(
        source: AudioInputSource,
        hostTimeNanoseconds: UInt64,
        samples: [Float]
    ) {
        self.source = source
        self.hostTimeNanoseconds = hostTimeNanoseconds
        self.samples = samples
    }
}

public final class DualInputSynchronizer: @unchecked Sendable {
    public enum SynchronizerError: Error, Equatable, Sendable {
        case noSources
        case unsupportedSampleRate
        case unexpectedSource
    }

    public let sampleRate: Int
    public let frameDurationMilliseconds: Int
    public let sources: Set<AudioInputSource>
    public let channelCount: Int

    private let samplesPerChannelFrame: Int64
    private let lock = NSLock()
    private var originHostTimeNanoseconds: UInt64?
    private var samples: [AudioInputSource: [Int64: Int16]] = [:]
    private var watermarks: [AudioInputSource: Int64] = [:]
    private var nextFrameStart: Int64 = 0
    private var microphoneMuted = false

    public init(
        sources: Set<AudioInputSource>,
        sampleRate: Int = 48_000,
        frameDurationMilliseconds: Int = 100,
        originHostTimeNanoseconds: UInt64? = nil
    ) throws {
        guard !sources.isEmpty else { throw SynchronizerError.noSources }
        guard sampleRate > 0,
              frameDurationMilliseconds > 0,
              (sampleRate * frameDurationMilliseconds).isMultiple(of: 1_000) else {
            throw SynchronizerError.unsupportedSampleRate
        }
        self.sources = sources
        self.sampleRate = sampleRate
        self.frameDurationMilliseconds = frameDurationMilliseconds
        self.channelCount = sources.count == 2 ? 2 : 1
        self.samplesPerChannelFrame = Int64(sampleRate * frameDurationMilliseconds / 1_000)
        self.originHostTimeNanoseconds = originHostTimeNanoseconds
        for source in sources {
            samples[source] = [:]
            watermarks[source] = 0
        }
    }

    public func setMicrophoneMuted(_ muted: Bool) {
        lock.lock()
        microphoneMuted = muted
        lock.unlock()
    }

    public func append(_ chunk: TimedAudioChunk) throws -> [[Int16]] {
        guard sources.contains(chunk.source) else {
            throw SynchronizerError.unexpectedSource
        }
        guard !chunk.samples.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }

        if originHostTimeNanoseconds == nil {
            originHostTimeNanoseconds = chunk.hostTimeNanoseconds
        }
        let origin = originHostTimeNanoseconds ?? chunk.hostTimeNanoseconds
        let delta = chunk.hostTimeNanoseconds >= origin
            ? chunk.hostTimeNanoseconds - origin
            : 0
        let start = Int64((Double(delta) * Double(sampleRate) / 1_000_000_000).rounded())

        var sourceSamples = samples[chunk.source] ?? [:]
        sourceSamples.reserveCapacity(sourceSamples.count + chunk.samples.count)
        for (offset, value) in chunk.samples.enumerated() {
            let index = start + Int64(offset)
            guard index >= nextFrameStart else { continue }
            sourceSamples[index] = Self.pcm16(value)
        }
        samples[chunk.source] = sourceSamples
        watermarks[chunk.source] = max(watermarks[chunk.source] ?? 0, start + Int64(chunk.samples.count))

        return drainCompleteFrames()
    }

    public func flush() -> [Int16]? {
        lock.lock()
        defer { lock.unlock() }
        let finalIndex = watermarks.values.max() ?? nextFrameStart
        guard finalIndex > nextFrameStart else {
            resetUnlocked()
            return nil
        }
        let frame = render(start: nextFrameStart, end: finalIndex)
        resetUnlocked()
        return frame.isEmpty ? nil : frame
    }

    public func reset() {
        lock.lock()
        resetUnlocked()
        lock.unlock()
    }

    private func resetUnlocked() {
        originHostTimeNanoseconds = nil
        nextFrameStart = 0
        for source in sources {
            samples[source] = [:]
            watermarks[source] = 0
        }
    }

    private func drainCompleteFrames() -> [[Int16]] {
        var frames: [[Int16]] = []
        while sources.allSatisfy({ (watermarks[$0] ?? 0) >= nextFrameStart + samplesPerChannelFrame }) {
            let end = nextFrameStart + samplesPerChannelFrame
            frames.append(render(start: nextFrameStart, end: end))
            discard(before: end)
            nextFrameStart = end
        }
        return frames
    }

    private func render(start: Int64, end: Int64) -> [Int16] {
        var output: [Int16] = []
        output.reserveCapacity(Int(end - start) * channelCount)
        for index in start..<end {
            if channelCount == 1 {
                let source = sources.contains(.microphone) ? AudioInputSource.microphone : .system
                let value = source == .microphone && microphoneMuted
                    ? 0
                    : samples[source]?[index] ?? 0
                output.append(value)
            } else {
                output.append(microphoneMuted ? 0 : samples[.microphone]?[index] ?? 0)
                output.append(samples[.system]?[index] ?? 0)
            }
        }
        return output
    }

    private func discard(before index: Int64) {
        for source in sources {
            samples[source] = samples[source]?.filter { $0.key >= index } ?? [:]
        }
    }

    private static func pcm16(_ value: Float) -> Int16 {
        let bounded = min(max(value.isFinite ? value : 0, -1), 1)
        if bounded <= -1 { return .min }
        return Int16((bounded * Float(Int16.max)).rounded())
    }
}
