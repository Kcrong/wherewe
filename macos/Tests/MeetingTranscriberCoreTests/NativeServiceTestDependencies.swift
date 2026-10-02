import Foundation
@testable import MeetingTranscriberCore

enum DeterministicTranslationBehavior: Equatable, Sendable {
    case succeed
    case fail
}

private enum DeterministicRuntimeError: Error, Sendable {
    case translationUnavailable
    case readinessTimeout
}

private actor DeterministicSpeechState {
    private static let supported = Set(["en-US", "ko-KR", "ja-JP", "zh-CN"])
    private var installed: Set<String>

    init(ready: Bool) {
        installed = ready ? Self.supported : []
    }

    func readiness(language: String) -> NativeSpeechReadiness {
        guard Self.supported.contains(language) else { return .unsupported }
        return installed.contains(language) ? .ready : .installationRequired
    }

    func install(language: String) throws {
        guard Self.supported.contains(language) else {
            throw NativeAppleSpeechError.unsupportedLocale(language)
        }
        installed.insert(language)
    }
}

struct DeterministicSpeechService: NativeSpeechServing {
    let text: String
    private let state: DeterministicSpeechState

    init(
        text: String = "Hello world from deterministic speech.",
        ready: Bool = true
    ) {
        self.text = text
        self.state = DeterministicSpeechState(ready: ready)
    }

    func isAvailable() -> Bool { true }

    func readiness(language: String) async -> NativeSpeechReadiness {
        await state.readiness(language: language)
    }

    func prepare(language: String, mode: String, showDetails: Bool) async throws {
        try await state.install(language: language)
    }

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

actor SuspendedSpeechReadinessGate {
    private var requestCount = 0
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func readiness() async -> NativeSpeechReadiness {
        requestCount += 1
        await withCheckedContinuation { releaseWaiters.append($0) }
        return .ready
    }

    func waitUntilRequests(_ expected: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while requestCount < expected {
            guard clock.now < deadline else {
                throw DeterministicRuntimeError.readinessTimeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseAll() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

struct SuspendedReadySpeechService: NativeSpeechServing {
    let gate: SuspendedSpeechReadinessGate

    func isAvailable() -> Bool { true }

    func readiness(language: String) async -> NativeSpeechReadiness {
        await gate.readiness()
    }

    func prepare(language: String, mode: String, showDetails: Bool) async throws {}

    func transcribe(
        language: String,
        sampleRate: Double,
        pcm: Data,
        mode: String,
        showDetails: Bool
    ) async throws -> NativeTranscriptionResult {
        NativeTranscriptionResult(text: "Suspended readiness speech.", alternatives: [], confidence: 1)
    }
}

struct SuspendedPrepareSpeechService: NativeSpeechServing {
    let gate: SuspendedSpeechReadinessGate

    func isAvailable() -> Bool { true }

    func readiness(language: String) async -> NativeSpeechReadiness { .ready }

    func prepare(language: String, mode: String, showDetails: Bool) async throws {
        _ = await gate.readiness()
    }

    func transcribe(
        language: String,
        sampleRate: Double,
        pcm: Data,
        mode: String,
        showDetails: Bool
    ) async throws -> NativeTranscriptionResult {
        NativeTranscriptionResult(text: "Suspended preparation speech.", alternatives: [], confidence: 1)
    }
}

actor SpeechPrepareCallCounter {
    private var calls = 0

    func record() { calls += 1 }
    func value() -> Int { calls }
}

struct CountingSpeechService: NativeSpeechServing {
    let counter: SpeechPrepareCallCounter

    func isAvailable() -> Bool { true }
    func readiness(language: String) async -> NativeSpeechReadiness { .ready }

    func prepare(language: String, mode: String, showDetails: Bool) async throws {
        await counter.record()
    }

    func transcribe(
        language: String,
        sampleRate: Double,
        pcm: Data,
        mode: String,
        showDetails: Bool
    ) async throws -> NativeTranscriptionResult {
        NativeTranscriptionResult(text: "Counted speech.", alternatives: [], confidence: 1)
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
    translationBehavior: DeterministicTranslationBehavior = .succeed,
    speechReady: Bool = true
) -> NativeService {
    NativeService(
        configuration: configuration,
        eventHub: eventHub,
        speechService: DeterministicSpeechService(ready: speechReady),
        translationService: DeterministicTranslationService(behavior: translationBehavior)
    )
}
