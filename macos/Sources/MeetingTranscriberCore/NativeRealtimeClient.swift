import Foundation

public final class NativeRealtimeHub: @unchecked Sendable {
    private struct Registration {
        let continuation: AsyncStream<RealtimeMessage>.Continuation
        var active: Bool
    }

    private let lock = NSLock()
    private var registrations: [UUID: Registration] = [:]

    public init() {}

    func register(_ id: UUID, continuation: AsyncStream<RealtimeMessage>.Continuation) {
        lock.lock()
        registrations[id] = Registration(continuation: continuation, active: false)
        lock.unlock()
    }

    func setActive(_ id: UUID, _ active: Bool) {
        lock.lock()
        if var registration = registrations[id] {
            registration.active = active
            registrations[id] = registration
        }
        lock.unlock()
    }

    func unregister(_ id: UUID) {
        lock.lock()
        let continuation = registrations.removeValue(forKey: id)?.continuation
        lock.unlock()
        continuation?.finish()
    }

    func registrationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return registrations.count
    }

    func publish(_ message: RealtimeMessage) {
        lock.lock()
        let targets = registrations.values.filter(\.active).map(\.continuation)
        lock.unlock()
        for continuation in targets { continuation.yield(message) }
    }
}

public final class NativeRealtimeClient: RealtimeServing, @unchecked Sendable {
    private static let spoolWorkspace: Result<NativeSpoolWorkspace, Error> = Result {
        try NativeSpoolWorkspace()
    }

    public let messages: AsyncStream<RealtimeMessage>
    public var clientID: String? { identifier.uuidString }

    private struct AudioSession {
        let id = UUID()
        let request: StartTranscriptionRequest
        let url: URL
        let handle: FileHandle
        var resultIDs: [String]
        var byteCount = 0
        var processedByteCount = 0
        var lastPreviewByteCount = 0
        var previewInFlight = false
    }

    private struct PreviewWork {
        let sessionID: UUID
        let url: URL
        let request: StartTranscriptionRequest
        let resultIDs: [String]
        let startByte: Int
        let endByte: Int
        let commit: Bool
    }

    private let identifier = UUID()
    private let service: NativeService
    private let hub: NativeRealtimeHub
    private let continuation: AsyncStream<RealtimeMessage>.Continuation
    private let lock = NSLock()
    private var connected = false
    private var audioSession: AudioSession?
    private var previewTasks: [UUID: Task<Void, Never>] = [:]
    private var preparationTasks: [UUID: Task<Void, Never>] = [:]

    public init(service: NativeService, hub: NativeRealtimeHub? = nil) {
        self.service = service
        self.hub = hub ?? service.eventHub
        let pair = AsyncStream.makeStream(
            of: RealtimeMessage.self,
            bufferingPolicy: .bufferingNewest(1_024)
        )
        self.messages = pair.stream
        self.continuation = pair.continuation
        self.hub.register(identifier, continuation: pair.continuation)
        _ = Self.spoolWorkspace
    }

    deinit {
        cancelPreviewTasks()
        cancelPreparationTasks()
        if let session = withLock({ audioSession }) { discard(session) }
        let service = self.service
        let clientID = identifier.uuidString
        Task { await service.clientDisconnected(clientID) }
        hub.unregister(identifier)
    }

    public func connect() async throws {
        let shouldPublish = withLock {
            let value = !connected
            connected = true
            return value
        }
        if shouldPublish {
            hub.setActive(identifier, true)
            await service.clientConnected(identifier.uuidString)
            continuation.yield(RealtimeMessage(name: .connected))
        }
    }

    public func disconnect() {
        let state = withLock { () -> (Bool, AudioSession?) in
            let value = (connected, audioSession)
            connected = false
            audioSession = nil
            return value
        }
        cancelPreviewTasks()
        cancelPreparationTasks()
        if let session = state.1 { discard(session) }
        hub.setActive(identifier, false)
        if state.0 {
            Task { await service.clientDisconnected(identifier.uuidString) }
            continuation.yield(RealtimeMessage(name: .disconnected))
        }
    }

    public func startTranscription(_ request: StartTranscriptionRequest) {
        let session: AudioSession
        do {
            session = try makeAudioSession(request)
        } catch {
            continuation.yield(RealtimeMessage(name: .transcribeError, payload: Self.payload([
                "code": "NATIVE_AUDIO_SPOOL_FAILED",
                "message": error.localizedDescription,
                "generation": request.generation,
            ])))
            return
        }
        let replacement = withLock { () -> (accepted: Bool, previous: AudioSession?) in
            guard connected else { return (false, nil) }
            let previous = audioSession
            audioSession = session
            return (true, previous)
        }
        guard replacement.accepted else {
            discard(session)
            continuation.yield(RealtimeMessage(name: .transcribeError, payload: Self.payload([
                "code": "NATIVE_REALTIME_DISCONNECTED",
                "generation": request.generation,
            ])))
            return
        }
        if let previous = replacement.previous {
            cancelPreviewTasks(for: previous.id)
            cancelPreparationTasks(for: previous.id)
            discard(previous)
        }

        let sessionID = session.id
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let ready = try await service.prepareRealtimeTranscription(
                    request,
                    clientID: identifier.uuidString
                )
                guard !Task.isCancelled, isCurrentSession(sessionID) else { return }
                continuation.yield(RealtimeMessage(name: .readyForAudio, payload: Self.encoded(ready)))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, isCurrentSession(sessionID) else { return }
                continuation.yield(RealtimeMessage(name: .transcribeError, payload: Self.payload([
                    "code": "APPLE_TRANSCRIPTION_PREPARE",
                    "message": error.localizedDescription,
                    "generation": request.generation,
                ])))
            }
        }
        let tracked = withLock { () -> Bool in
            guard audioSession?.id == sessionID else { return false }
            preparationTasks[sessionID] = task
            return true
        }
        if !tracked { task.cancel() }
    }

    public func sendAudio(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let work: PreviewWork? = try withLock {
            guard connected, var session = audioSession else { throw RealtimeClientError.disconnected }
            try session.handle.write(contentsOf: data)
            session.byteCount += data.count
            let bytesPerSecond = max(1, Int(session.request.sampleRate) * session.request.channelCount * 2)
            let previewThreshold = bytesPerSecond * 2
            let commitThreshold = bytesPerSecond * 10
            let unprocessed = session.byteCount - session.processedByteCount
            let shouldCommit = unprocessed >= commitThreshold
            let shouldPreview = session.byteCount - session.lastPreviewByteCount >= previewThreshold
            guard !session.previewInFlight, shouldCommit || shouldPreview else {
                audioSession = session
                return nil
            }
            try session.handle.synchronize()
            session.previewInFlight = true
            session.lastPreviewByteCount = session.byteCount
            let work = PreviewWork(
                sessionID: session.id,
                url: session.url,
                request: session.request,
                resultIDs: session.resultIDs,
                startByte: session.processedByteCount,
                endByte: session.byteCount,
                commit: shouldCommit
            )
            audioSession = session
            return work
        }
        if let work {
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runPreview(work)
            }
            let tracked = withLock { () -> Bool in
                guard audioSession?.id == work.sessionID else { return false }
                previewTasks[work.sessionID]?.cancel()
                previewTasks[work.sessionID] = task
                return true
            }
            if !tracked { task.cancel() }
        }
    }

    public func audioBarrier(
        meetingID: Int,
        generation: Int64
    ) async throws -> RealtimeAcknowledgement {
        let byteCounts = try withLock { () -> (tracked: Int, stored: Int)? in
            guard let session = audioSession,
                  session.request.meetingID == meetingID,
                  session.request.generation == generation else { return nil }
            try session.handle.synchronize()
            return (session.byteCount, Int(try session.handle.offset()))
        }
        let matches = byteCounts.map { $0.tracked == $0.stored } ?? false
        let code: String? = if matches {
            nil
        } else if byteCounts == nil {
            "AUDIO_BARRIER_NOT_OWNED"
        } else {
            "AUDIO_DELIVERY_INCOMPLETE"
        }
        return RealtimeAcknowledgement(
            success: matches,
            code: code,
            meetingID: meetingID,
            generation: generation,
            audioByteCount: byteCounts?.stored
        )
    }

    public func stopTranscription(
        meetingID: Int,
        generation: Int64
    ) async throws -> RealtimeAcknowledgement {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while withLock({ audioSession?.previewInFlight == true }), clock.now < deadline {
            try await clock.sleep(for: .milliseconds(25))
        }
        guard !withLock({ audioSession?.previewInFlight == true }) else {
            throw RealtimeClientError.acknowledgementTimedOut
        }
        let session = withLock { audioSession }
        guard let session,
              session.request.meetingID == meetingID,
              session.request.generation == generation else {
            let status = try await service.recordingStatus(socketID: identifier.uuidString)
            guard status.recordingMeetingID == meetingID,
                  status.recordingGeneration == generation else {
                return RealtimeAcknowledgement(
                    success: false,
                    code: "RECORDING_CLAIM_STALE",
                    meetingID: meetingID,
                    generation: generation
                )
            }
            let code = status.recordingOwnedByRequester || !status.recordingOwnerConnected
                ? "AUDIO_SESSION_UNAVAILABLE"
                : "RECORDING_OWNED_BY_ANOTHER_CLIENT"
            return RealtimeAcknowledgement(
                success: false,
                code: code,
                meetingID: meetingID,
                generation: generation
            )
        }
        cancelPreviewTasks(for: session.id)
        cancelPreparationTasks(for: session.id)
        try session.handle.synchronize()
        let audio = try readSpool(
            session.url,
            from: session.processedByteCount,
            to: session.byteCount
        )
        do {
            let messages = try await service.finishRealtimeTranscription(
                session.request,
                audio: audio,
                resultIDs: session.resultIDs,
                clientID: identifier.uuidString
            )
            let released = withLock { () -> Bool in
                guard audioSession?.id == session.id else { return false }
                audioSession = nil
                return true
            }
            if released {
                try? session.handle.close()
                try? FileManager.default.removeItem(at: session.url)
            }
            for message in messages { continuation.yield(message) }
            return RealtimeAcknowledgement(
                success: true,
                code: nil,
                meetingID: meetingID,
                generation: generation
            )
        } catch {
            continuation.yield(RealtimeMessage(name: .transcribeError, payload: Self.payload([
                "code": "APPLE_TRANSCRIPTION_FAILED",
                "message": error.localizedDescription,
                "generation": generation,
            ])))
            throw error
        }
    }

    private func makeAudioSession(_ request: StartTranscriptionRequest) throws -> AudioSession {
        let spool = try Self.spoolWorkspace.get().makeSpoolFile()
        return AudioSession(
            request: request,
            url: spool.url,
            handle: spool.handle,
            resultIDs: (0..<request.channelCount).map { _ in UUID().uuidString }
        )
    }

    private func readSpool(_ url: URL, from start: Int, to end: Int) throws -> Data {
        guard start >= 0, end >= start else { throw NativeServiceError.decoding }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(start))
        return try reader.read(upToCount: end - start) ?? Data()
    }

    private func discard(_ session: AudioSession) {
        try? session.handle.close()
        try? FileManager.default.removeItem(at: session.url)
    }

    private func runPreview(_ work: PreviewWork) async {
        var committed = false
        var committedEnd = work.endByte
        defer {
            withLock {
                guard var current = audioSession,
                      current.id == work.sessionID,
                      current.request.generation == work.request.generation else { return }
                if work.commit, committed, current.processedByteCount == work.startByte {
                    current.processedByteCount = committedEnd
                    current.resultIDs = (0..<work.request.channelCount).map { _ in UUID().uuidString }
                }
                current.previewInFlight = false
                audioSession = current
            }
        }
        guard !Task.isCancelled, isCurrentSession(work.sessionID) else { return }
        guard var data = try? readSpool(work.url, from: work.startByte, to: work.endByte) else { return }
        if work.commit {
            let length = PCMCommitBoundary.commitLength(
                of: data,
                channelCount: work.request.channelCount,
                sampleRate: work.request.sampleRate
            )
            data = data.prefix(length)
            committedEnd = work.startByte + length
        }
        do {
            let messages: [RealtimeMessage]
            if work.commit {
                messages = try await service.commitRealtimeChunk(
                    work.request,
                    audio: data,
                    resultIDs: work.resultIDs,
                    clientID: identifier.uuidString
                )
                committed = true
            } else {
                messages = try await service.previewRealtimeTranscription(
                    work.request,
                    audio: data,
                    resultIDs: work.resultIDs,
                    clientID: identifier.uuidString
                )
            }
            guard !Task.isCancelled, isCurrentSession(work.sessionID) else { return }
            for message in messages { continuation.yield(message) }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, isCurrentSession(work.sessionID) else { return }
            continuation.yield(RealtimeMessage(name: .transcribeError, payload: Self.payload([
                "code": "APPLE_TRANSCRIPTION_CHUNK_FAILED",
                "message": error.localizedDescription,
                "generation": work.request.generation,
            ])))
        }
    }

    private func isCurrentSession(_ sessionID: UUID) -> Bool {
        withLock { connected && audioSession?.id == sessionID }
    }

    private func cancelPreviewTasks(for sessionID: UUID? = nil) {
        let tasks = withLock { () -> [Task<Void, Never>] in
            if let sessionID {
                return previewTasks.removeValue(forKey: sessionID).map { [$0] } ?? []
            }
            let values = Array(previewTasks.values)
            previewTasks.removeAll()
            return values
        }
        tasks.forEach { $0.cancel() }
    }

    private func cancelPreparationTasks(for sessionID: UUID? = nil) {
        let tasks = withLock { () -> [Task<Void, Never>] in
            if let sessionID {
                return preparationTasks.removeValue(forKey: sessionID).map { [$0] } ?? []
            }
            let values = Array(preparationTasks.values)
            preparationTasks.removeAll()
            return values
        }
        tasks.forEach { $0.cancel() }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func encoded<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private static func payload(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }
}
