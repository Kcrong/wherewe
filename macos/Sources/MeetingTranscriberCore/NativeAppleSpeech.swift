import AVFoundation
import CoreMedia
import Foundation
import Speech

struct NativeTranscriptionResult: Sendable {
    let text: String
    let alternatives: [String]
    let confidence: Double?
}

func nativeSpeechLanguageLabel(_ identifier: String) -> String {
    switch identifier {
    case "en-US": "English"
    case "ko-KR": "Korean"
    case "ja-JP": "Japanese"
    case "zh-CN": "Chinese"
    default: identifier
    }
}

enum NativeSpeechReadiness: Equatable, Sendable {
    case unavailable
    case unsupported
    case installationRequired
    case ready
}

protocol NativeSpeechServing: Sendable {
    func isAvailable() -> Bool
    func readiness(language: String) async -> NativeSpeechReadiness
    func prepare(language: String, mode: String, showDetails: Bool) async throws
    func transcribe(
        language: String,
        sampleRate: Double,
        pcm: Data,
        mode: String,
        showDetails: Bool
    ) async throws -> NativeTranscriptionResult
}

struct NativeAppleSpeechService: NativeSpeechServing {
    func isAvailable() -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return NativeAppleSpeech.isAvailable
    }

    func readiness(language: String) async -> NativeSpeechReadiness {
        guard #available(macOS 26.0, *) else { return .unavailable }
        return await NativeAppleSpeech.readiness(language: language)
    }

    func prepare(language: String, mode: String, showDetails: Bool) async throws {
        guard #available(macOS 26.0, *) else { throw NativeAppleSpeechError.unavailable }
        _ = try await NativeAppleSpeech.prepare(
            language: language,
            mode: mode,
            showDetails: showDetails
        )
    }

    func transcribe(
        language: String,
        sampleRate: Double,
        pcm: Data,
        mode: String,
        showDetails: Bool
    ) async throws -> NativeTranscriptionResult {
        guard #available(macOS 26.0, *) else { throw NativeAppleSpeechError.unavailable }
        return try await NativeAppleSpeech.transcribe(
            language: language,
            sampleRate: sampleRate,
            pcm: pcm,
            mode: mode,
            showDetails: showDetails
        )
    }
}

enum NativeAppleSpeechError: Error, LocalizedError {
    case unavailable
    case unsupportedLocale(String)
    case invalidPCM
    case noFormat
    case conversion
    case assetInstallationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple SpeechAnalyzer is unavailable on this Mac."
        case let .unsupportedLocale(locale): "Apple SpeechAnalyzer does not support locale \(locale)."
        case .invalidPCM: "Apple SpeechAnalyzer received invalid PCM audio."
        case .noFormat: "Apple SpeechAnalyzer did not provide a compatible audio format."
        case .conversion: "Audio conversion for Apple SpeechAnalyzer failed."
        case let .assetInstallationFailed(locale): "macOS could not install \(nativeSpeechLanguageLabel(locale)) Speech assets. Check your internet connection and available storage, then try again."
        }
    }
}

enum NativeAppleSpeech {
    /// Whether this Mac exposes SpeechAnalyzer at all. Hosted CI runners
    /// frequently report `false` even on macOS 26, so callers that only want
    /// to skip rather than fail can probe this first.
    @available(macOS 26.0, *)
    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    @available(macOS 26.0, *)
    static func readiness(language: String) async -> NativeSpeechReadiness {
        guard SpeechTranscriber.isAvailable else { return .unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language)
        ) else { return .unsupported }
        let identifier = locale.identifier(.bcp47)
        let installedLocales = await SpeechTranscriber.installedLocales
        return installedLocales.contains { $0.identifier(.bcp47) == identifier }
            ? .ready
            : .installationRequired
    }

    @available(macOS 26.0, *)
    static func prepare(
        language: String,
        mode: String = "live",
        showDetails: Bool = false
    ) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw NativeAppleSpeechError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language)
        ) else { throw NativeAppleSpeechError.unsupportedLocale(language) }
        var reporting: Set<SpeechTranscriber.ReportingOption> = []
        if mode == "live" { reporting.formUnion([.volatileResults, .fastResults]) }
        if showDetails { reporting.insert(.alternativeTranscriptions) }
        let attributes: Set<SpeechTranscriber.ResultAttributeOption> = showDetails
            ? [.transcriptionConfidence]
            : []
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reporting,
            attributeOptions: attributes
        )
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .unsupported { throw NativeAppleSpeechError.unsupportedLocale(language) }
        if status != .installed {
            try Task.checkCancellation()
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                throw NativeAppleSpeechError.assetInstallationFailed(language)
            }
            try Task.checkCancellation()
            let installedStatus = await AssetInventory.status(forModules: [transcriber])
            guard installedStatus == .installed else {
                throw NativeAppleSpeechError.assetInstallationFailed(language)
            }
        }
        return transcriber
    }

    @available(macOS 26.0, *)
    static func transcribe(
        language: String,
        sampleRate: Double,
        pcm: Data,
        mode: String,
        showDetails: Bool
    ) async throws -> NativeTranscriptionResult {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { throw NativeAppleSpeechError.invalidPCM }
        let transcriber = try await prepare(language: language, mode: mode, showDetails: showDetails)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NativeAppleSpeechError.noFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let pair = AsyncStream.makeStream(of: AnalyzerInput.self)
        let resultsTask = Task { () throws -> NativeTranscriptionResult in
            var finals: [(String, [String], Double?)] = []
            var latest: (String, [String], Double?)?
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let alternatives = showDetails
                    ? result.alternatives.map { String($0.characters).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && $0 != text }
                    : []
                let confidence = showDetails ? confidence(in: result.text) : nil
                if result.isFinal { finals.append((text, alternatives, confidence)) }
                else { latest = (text, alternatives, confidence) }
            }
            if !finals.isEmpty {
                let text = finals.map(\.0).joined(separator: " ")
                let confidences = finals.compactMap(\.2)
                return NativeTranscriptionResult(
                    text: text,
                    alternatives: combinedAlternatives(finals, transcript: text),
                    confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
                )
            }
            guard let latest else { return NativeTranscriptionResult(text: "", alternatives: [], confidence: nil) }
            return NativeTranscriptionResult(
                text: latest.0,
                alternatives: Array(latest.1.prefix(3)),
                confidence: latest.2
            )
        }
        do {
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            try await analyzer.start(inputSequence: pair.stream)
            let source = try pcmBuffer(data: pcm, sampleRate: sampleRate)
            for buffer in try convert(source, to: analyzerFormat) {
                pair.continuation.yield(AnalyzerInput(buffer: buffer))
            }
            pair.continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await resultsTask.value
        } catch {
            pair.continuation.finish()
            await analyzer.cancelAndFinishNow()
            resultsTask.cancel()
            throw error
        }
    }

    @available(macOS 26.0, *)
    private static func confidence(in text: AttributedString) -> Double? {
        let values = text.runs.compactMap {
            $0[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
        }
        guard !values.isEmpty else { return nil }
        return max(0, min(1, values.reduce(0, +) / Double(values.count)))
    }

    @available(macOS 26.0, *)
    private static func combinedAlternatives(
        _ segments: [(String, [String], Double?)],
        transcript: String
    ) -> [String] {
        let count = min(3, segments.map { $0.1.count }.max() ?? 0)
        return (0..<count).compactMap { index in
            let value = segments.map { index < $0.1.count ? $0.1[index] : $0.0 }.joined(separator: " ")
            return value == transcript ? nil : value
        }
    }

    private static func pcmBuffer(data: Data, sampleRate: Double) throws -> AVAudioPCMBuffer {
        guard sampleRate >= 8_000, sampleRate <= 192_000,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(data.count / 2)
              ),
              let channel = buffer.int16ChannelData?[0] else {
            throw NativeAppleSpeechError.invalidPCM
        }
        buffer.frameLength = AVAudioFrameCount(data.count / 2)
        data.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Int16.self).baseAddress else { return }
            channel.update(from: source, count: data.count / 2)
        }
        return buffer
    }

    private static func convert(
        _ source: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) throws -> [AVAudioPCMBuffer] {
        if source.format == format { return [source] }
        guard let converter = AVAudioConverter(from: source.format, to: format) else {
            throw NativeAppleSpeechError.conversion
        }
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = max(1, AVAudioFrameCount((Double(source.frameLength) * ratio).rounded(.up)) + 4_096)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw NativeAppleSpeechError.conversion
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if !supplied {
                supplied = true
                inputStatus.pointee = .haveData
                return source
            }
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, output.frameLength > 0 else {
            throw conversionError ?? NativeAppleSpeechError.conversion
        }
        return [output]
    }
}
