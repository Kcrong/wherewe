import Foundation

/// Turns captured interleaved PCM16 into per-channel input levels for the
/// recording indicator, so the user can see that audio is actually arriving.
///
/// Levels are RMS over a fixed window, mapped from -60…0 dBFS onto 0…1, and
/// reported once per window rather than per frame to keep UI updates cheap.
public struct CaptureLevelMeter: Sendable {
    public static let floorDecibels = -60.0

    public let channelCount: Int
    private let windowFrames: Int
    private var sums: [Double]
    private var framesInWindow = 0

    /// - Parameters:
    ///   - windowSeconds: how much audio each reported level summarises.
    public init(channelCount: Int, sampleRate: Double, windowSeconds: Double = 0.1) {
        self.channelCount = max(1, channelCount)
        self.windowFrames = max(1, Int(sampleRate * windowSeconds))
        self.sums = Array(repeating: 0, count: max(1, channelCount))
    }

    /// Adds interleaved samples. Returns the levels of the most recently
    /// completed window, or nil while the current window is still filling.
    public mutating func consume(_ interleaved: [Int16]) -> [Double]? {
        var completed: [Double]?
        var index = 0
        while index + channelCount <= interleaved.count {
            for channel in 0..<channelCount {
                let value = Double(interleaved[index + channel]) / Double(Int16.max)
                sums[channel] += value * value
            }
            index += channelCount
            framesInWindow += 1
            if framesInWindow == windowFrames {
                completed = sums.map { Self.level(meanSquare: $0 / Double(windowFrames)) }
                sums = Array(repeating: 0, count: channelCount)
                framesInWindow = 0
            }
        }
        return completed
    }

    /// Maps a mean-square amplitude (full scale = 1) onto 0…1.
    public static func level(meanSquare: Double) -> Double {
        guard meanSquare > 0 else { return 0 }
        let decibels = 10 * log10(meanSquare)
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }
}
