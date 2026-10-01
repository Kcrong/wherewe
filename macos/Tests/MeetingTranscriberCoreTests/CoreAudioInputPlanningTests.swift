import Testing
import Testing
@testable import MeetingTranscriberCore

@Suite("CoreAudio input planning")
struct CoreAudioInputPlanningTests {
    @Test("default microphone retains voice processing without device binding")
    func defaultMicrophoneUsesVoiceProcessing() {
        #expect(CoreAudioInputStream.shouldUseVoiceProcessingIO(
            processingMode: .voiceProcessedMicrophone,
            isDefaultInput: true
        ))
    }

    @Test("non-default microphone uses selectable AUHAL capture")
    func nonDefaultMicrophoneUsesAUHAL() {
        #expect(!CoreAudioInputStream.shouldUseVoiceProcessingIO(
            processingMode: .voiceProcessedMicrophone,
            isDefaultInput: false
        ))
    }

    @Test("system input always uses unprocessed AUHAL capture")
    func systemInputUsesAUHAL() {
        #expect(!CoreAudioInputStream.shouldUseVoiceProcessingIO(
            processingMode: .unprocessedSystemInput,
            isDefaultInput: true
        ))
        #expect(!CoreAudioInputStream.shouldUseVoiceProcessingIO(
            processingMode: .unprocessedSystemInput,
            isDefaultInput: false
        ))
    }
}
