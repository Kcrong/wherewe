import Foundation
@testable import MeetingTranscriberCore

enum DeterministicTranslationBehavior: Equatable, Sendable {
    case succeed
    case fail
}

private enum DeterministicRuntimeError: Error, Sendable {
    case translationUnavailable
}

struct DeterministicSpeechService: NativeSpeechServing {
    let text: String

    init(text: String = "Hello world from deterministic speech.") {
        self.text = text
    }

    func isAvailable() -> Bool { true }

    func prepare(language: String, mode: String, showDetails: Bool) async throws {}

    func transcribe(
        language: String,
        sampleRate: Double,
        pcm: Data,
        mode: String,
        showDetails: Bool
    ) async throws -> NativeTranscriptionResult {
        guard pcm.contains(where: { $0 != 0 }) else {
            return NativeTranscriptionResult(text: "", alternatives: [], confidence: nil)
        }
        return NativeTranscriptionResult(text: text, alternatives: [], confidence: 1)
    }
}

actor DeterministicTranslationService: NativeTranslationServing {
    let behavior: DeterministicTranslationBehavior

    init(behavior: DeterministicTranslationBehavior = .succeed) {
        self.behavior = behavior
    }

    func status(source: String, target: String) async throws -> String {
        "installed"
    }

    func translate(_ text: String, source: String, target: String) async throws -> String {
        guard behavior == .succeed else { throw DeterministicRuntimeError.translationUnavailable }
        return "Translated: \(text)"
    }

    func reset() async {}
}

func makeTestService(
    configuration: NativeServiceConfiguration,
    eventHub: NativeRealtimeHub = NativeRealtimeHub(),
    translationBehavior: DeterministicTranslationBehavior = .succeed
) -> NativeService {
    NativeService(
        configuration: configuration,
        eventHub: eventHub,
        speechService: DeterministicSpeechService(),
        translationService: DeterministicTranslationService(behavior: translationBehavior)
    )
}
