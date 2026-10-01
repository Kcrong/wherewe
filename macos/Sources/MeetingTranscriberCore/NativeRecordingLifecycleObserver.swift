import Foundation

struct NativeRecordingLifecycleObserver: Sendable {
    let beforeTranscriptInsert: @Sendable (StartTranscriptionRequest) async -> Void
    let beforeFinishClaimClear: @Sendable (StartTranscriptionRequest) async -> Void
    let beforeFinalizeRecording: @Sendable (FinalizeRecordingRequest) async throws -> Void

    init(
        beforeTranscriptInsert: @escaping @Sendable (StartTranscriptionRequest) async -> Void = { _ in },
        beforeFinishClaimClear: @escaping @Sendable (StartTranscriptionRequest) async -> Void = { _ in },
        beforeFinalizeRecording: @escaping @Sendable (FinalizeRecordingRequest) async throws -> Void = { _ in }
    ) {
        self.beforeTranscriptInsert = beforeTranscriptInsert
        self.beforeFinishClaimClear = beforeFinishClaimClear
        self.beforeFinalizeRecording = beforeFinalizeRecording
    }
}

extension NativeService {
    func setRecordingLifecycleObserver(_ observer: NativeRecordingLifecycleObserver) {
        recordingLifecycleObserver = observer
    }
}
