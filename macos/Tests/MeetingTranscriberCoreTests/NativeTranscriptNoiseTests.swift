import Testing
@testable import MeetingTranscriberCore

@Suite("Native transcript noise")
struct NativeTranscriptNoiseTests {
    @Test("punctuation and single-character hallucinations are noise")
    func punctuationNoise() {
        for value in ["", ".", "...", "I", "a", "음", " uh! "] {
            #expect(NativeTranscriptNoise.isLikelyNoise(value), "Expected noise: \(value)")
        }
    }

    @Test("meaningful phrases remain")
    func meaningfulSpeech() {
        for value in ["Hello", "Can you hear me?", "안녕하세요"] {
            #expect(!NativeTranscriptNoise.isLikelyNoise(value), "Expected speech: \(value)")
        }
    }
}
