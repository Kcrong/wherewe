import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Native Apple runtimes", .serialized)
struct NativeRuntimeIntegrationTests {
    @Test("SpeechAnalyzer transcribes system-generated speech", .enabled(if: NativeRuntimeEvidence.isRequested("WHEREWE_NATIVE_REAL_APPLE_SPEECH", allowAuto: true), "Set WHEREWE_NATIVE_REAL_APPLE_SPEECH=1 or auto to run."))
    func realSpeechAnalyzer() async throws {
        let mode = realRuntimeMode("WHEREWE_NATIVE_REAL_APPLE_SPEECH")
        guard NativeAppleSpeech.isAvailable else {
            if mode == .required {
                Issue.record("Apple SpeechAnalyzer is required by WHEREWE_NATIVE_REAL_APPLE_SPEECH=1 but unavailable on this Mac")
            } else {
                print("SKIP: Apple SpeechAnalyzer is unavailable on this host (auto mode).")
            }
            return
        }
        let generated = try SyntheticSpeechFixture.make()
        defer { generated.remove() }
        let wav = generated.wav
        let result = try await NativeAppleSpeech.transcribe(
            language: "en-US",
            sampleRate: wav.sampleRate,
            pcm: wav.pcm,
            mode: "accurate",
            showDetails: true
        )
        #expect(result.text.localizedCaseInsensitiveContains("transcription system"))
        #expect(result.text.localizedCaseInsensitiveContains("hear me clearly"))
        #expect(result.confidence != nil)
        NativeRuntimeEvidence.record("apple-speech-accurate")
    }

    @Test("SpeechAnalyzer keeps a sentence whole across a realtime commit", .enabled(if: NativeRuntimeEvidence.isRequested("WHEREWE_NATIVE_REAL_APPLE_SPEECH", allowAuto: true), "Set WHEREWE_NATIVE_REAL_APPLE_SPEECH=1 or auto to run."))
    func realSpeechAnalyzerCommitBoundary() async throws {
        let mode = realRuntimeMode("WHEREWE_NATIVE_REAL_APPLE_SPEECH")
        guard NativeAppleSpeech.isAvailable else {
            if mode == .required {
                Issue.record("Apple SpeechAnalyzer is required by WHEREWE_NATIVE_REAL_APPLE_SPEECH=1 but unavailable on this Mac")
            } else {
                print("SKIP: Apple SpeechAnalyzer is unavailable on this host (auto mode).")
            }
            return
        }
        let generated = try SyntheticSpeechFixture.make()
        defer { generated.remove() }
        let wav = generated.wav
        let audio = Data(count: Int(6.4 * wav.sampleRate) * 2) + wav.pcm + Data(count: Int(wav.sampleRate) * 2)
        let pending = audio.prefix(Int(wav.sampleRate) * 2 * 10)
        let length = PCMCommitBoundary.commitLength(of: pending, channelCount: 1, sampleRate: wav.sampleRate)

        var lines: [String] = []
        var fixedCutLines: [String] = []
        for (cut, sink) in [(length, 0), (pending.count, 1)] {
            for part in [audio.prefix(cut), audio.dropFirst(cut)] where part.contains(where: { $0 != 0 }) {
                let result = try await NativeAppleSpeech.transcribe(
                    language: "en-US",
                    sampleRate: wav.sampleRate,
                    pcm: Data(part),
                    mode: "live",
                    showDetails: false
                )
                guard !result.text.isEmpty else { continue }
                if sink == 0 { lines.append(result.text) } else { fixedCutLines.append(result.text) }
            }
        }
        print("commit boundary: silence-aligned=\(lines) fixed-ten-second=\(fixedCutLines)")
        #expect(lines.count == 1, "expected one line, got \(lines)")
        #expect(lines.first?.localizedCaseInsensitiveContains("hear me clearly") == true)
        NativeRuntimeEvidence.record("apple-speech-commit-boundary")
    }

    @Test("Apple Translation performs a real installed-pack translation", .enabled(if: NativeRuntimeEvidence.isRequested("WHEREWE_NATIVE_REAL_APPLE_TRANSLATION", allowAuto: true), "Set WHEREWE_NATIVE_REAL_APPLE_TRANSLATION=1 or auto to run."))
    func realAppleTranslation() async throws {
        let mode = realRuntimeMode("WHEREWE_NATIVE_REAL_APPLE_TRANSLATION")
        let translator = NativeAppleTranslation()
        let state = try await translator.status(source: "en", target: "ko")
        guard state == "installed" else {
            if mode == .required {
                Issue.record("Apple Translation en->ko pack is required but reports \(state)")
            } else {
                print("SKIP: Apple Translation en->ko pack reports \(state) on this host (auto mode).")
            }
            return
        }
        let source = "This is an on-device installation test."
        let translated = try await translator.translate(source, source: "en", target: "ko")
        #expect(!translated.isEmpty)
        #expect(translated != source)
        NativeRuntimeEvidence.record("apple-translation")
    }

    private enum RealRuntimeMode { case off, required, auto }

    private func realRuntimeMode(_ key: String) -> RealRuntimeMode {
        switch ProcessInfo.processInfo.environment[key] {
        case "1": .required
        case "auto": .auto
        default: .off
        }
    }
}

struct WAVFixture {
    let sampleRate: Double
    let pcm: Data

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw WAVError.invalid
        }
        var offset = 12
        var rate: UInt32?
        var channels: UInt16?
        var bits: UInt16?
        var audio: Data?
        while offset + 8 <= data.count {
            let name = String(data: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let size = Int(Self.uint32(data, offset + 4))
            let start = offset + 8
            let end = min(data.count, start + size)
            if name == "fmt ", end - start >= 16 {
                channels = Self.uint16(data, start + 2)
                rate = Self.uint32(data, start + 4)
                bits = Self.uint16(data, start + 14)
            } else if name == "data" {
                audio = data[start..<end]
            }
            offset = end + (size.isMultiple(of: 2) ? 0 : 1)
        }
        guard let rate, channels == 1, bits == 16, let audio, !audio.isEmpty else {
            throw WAVError.unsupported
        }
        self.sampleRate = Double(rate)
        self.pcm = audio
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

private enum WAVError: Error {
    case invalid
    case unsupported
}
