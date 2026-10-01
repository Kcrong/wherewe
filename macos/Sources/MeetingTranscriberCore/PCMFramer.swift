import Foundation

public struct PCMFramer: Sendable {
    public enum FramingError: Error, Equatable, Sendable {
        case invalidSampleRate
        case invalidChannelCount
        case invalidFrameDuration
        case misalignedSamples
    }

    public let sampleRate: Int
    public let channelCount: Int
    public let frameDurationMilliseconds: Int
    public let samplesPerFrame: Int

    private var pending: [Int16] = []

    public init(
        sampleRate: Int = 48_000,
        channelCount: Int,
        frameDurationMilliseconds: Int = 100
    ) throws {
        guard sampleRate > 0 else { throw FramingError.invalidSampleRate }
        guard channelCount == 1 || channelCount == 2 else {
            throw FramingError.invalidChannelCount
        }
        let product = sampleRate * frameDurationMilliseconds
        guard frameDurationMilliseconds > 0, product.isMultiple(of: 1_000) else {
            throw FramingError.invalidFrameDuration
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameDurationMilliseconds = frameDurationMilliseconds
        self.samplesPerFrame = product / 1_000 * channelCount
        self.pending.reserveCapacity(samplesPerFrame * 2)
    }

    public var pendingSampleCount: Int {
        pending.count
    }

    public mutating func append(_ samples: [Int16]) throws -> [Data] {
        guard samples.count.isMultiple(of: channelCount) else {
            throw FramingError.misalignedSamples
        }
        pending.append(contentsOf: samples)

        var frames: [Data] = []
        while pending.count >= samplesPerFrame {
            frames.append(Self.littleEndianData(pending.prefix(samplesPerFrame)))
            pending.removeFirst(samplesPerFrame)
        }
        return frames
    }

    public mutating func flush() -> Data? {
        guard !pending.isEmpty else { return nil }
        let frame = Self.littleEndianData(pending[...])
        pending.removeAll(keepingCapacity: true)
        return frame
    }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    private static func littleEndianData<S: Sequence>(_ samples: S) -> Data where S.Element == Int16 {
        var data = Data()
        data.reserveCapacity(samples.underestimatedCount * MemoryLayout<Int16>.size)
        for sample in samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
