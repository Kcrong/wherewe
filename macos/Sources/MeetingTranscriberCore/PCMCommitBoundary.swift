import Foundation

/// Chooses where a committed transcription chunk should end.
///
/// Realtime capture commits roughly every ten seconds. Cutting at a fixed
/// byte count splits whatever word is being spoken, and the recogniser then
/// guesses at both halves ("…hear me clearly?" became "…hear me?" plus a
/// separate "Yearly?"). The cut is moved to the quietest short span in the
/// tail of the chunk instead, so it normally lands in a pause between words.
enum PCMCommitBoundary {
    /// Returns the number of bytes of `pcm` to commit now; the rest stays
    /// pending for the next chunk. The result is always frame-aligned and
    /// never earlier than `minimumSeconds` into the chunk.
    static func commitLength(
        of pcm: Data,
        channelCount: Int,
        sampleRate: Double,
        minimumSeconds: Double = 6,
        windowSeconds: Double = 0.02,
        spanWindows: Int = 10
    ) -> Int {
        let channels = max(1, channelCount)
        let frameBytes = channels * MemoryLayout<Int16>.size
        let frameCount = pcm.count / frameBytes
        let windowFrames = max(1, Int(sampleRate * windowSeconds))
        let windowCount = frameCount / windowFrames
        let firstWindow = Int((minimumSeconds / windowSeconds).rounded(.up))
        guard windowCount >= firstWindow + spanWindows else { return frameCount * frameBytes }

        // Mean square energy per window, all channels combined, so a pause
        // must be quiet on every channel before it is chosen.
        var energy = [Double](repeating: 0, count: windowCount)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for window in 0..<windowCount {
                let start = window * windowFrames * channels
                let end = start + windowFrames * channels
                var sum = 0.0
                for index in start..<end {
                    let value = Double(Int16(littleEndian: samples[index]))
                    sum += value * value
                }
                energy[window] = sum / Double(end - start)
            }
        }

        var spanEnergy = energy[firstWindow..<(firstWindow + spanWindows)].reduce(0, +)
        var best = (energy: spanEnergy, start: firstWindow)
        var start = firstWindow + 1
        while start + spanWindows <= windowCount {
            spanEnergy += energy[start + spanWindows - 1] - energy[start - 1]
            // `<=` prefers the latest equally quiet span, keeping chunks long.
            if spanEnergy <= best.energy { best = (spanEnergy, start) }
            start += 1
        }
        let cutFrame = (best.start + spanWindows / 2) * windowFrames
        return cutFrame * frameBytes
    }
}
