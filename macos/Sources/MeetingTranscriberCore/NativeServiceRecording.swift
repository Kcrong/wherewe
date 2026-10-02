import Foundation

extension NativeService {
    public func recordingStatus(socketID: String?) async throws -> RecordingStatus {
        let claim = recordingClaim
        return RecordingStatus(
            recordingMeetingID: claim?.meetingID,
            selectionLocked: claim != nil,
            recordingGeneration: claim?.generation,
            recordingOwnerConnected: claim.map { connectedClientIDs.contains($0.clientID) } ?? false,
            recordingOwnedByRequester: claim != nil && claim?.clientID == socketID
        )
    }

    public func recordingPreparation(meetingID: Int) async throws -> RecordingPreparation {
        let detail = try await meeting(id: meetingID)
        return await speechPreparation(language: detail.language)
    }

    private func speechPreparation(language: String) async -> RecordingPreparation {
        let available = speechService.isAvailable()
        let readiness: NativeSpeechReadiness
        if available {
            readiness = await speechService.readiness(language: language)
        } else {
            readiness = .unavailable
        }
        let languageLabel = nativeSpeechLanguageLabel(language)
        let message: String?
        switch readiness {
        case .ready:
            message = nil
        case .installationRequired:
            message = "Install \(languageLabel) Speech assets in Settings before recording."
        case .unsupported:
            message = "Apple SpeechAnalyzer does not support \(languageLabel)."
        case .unavailable:
            message = "Apple SpeechAnalyzer is unavailable for \(languageLabel) on this Mac."
        }
        return RecordingPreparation(
            state: readiness == .ready ? "ready" : "not-ready",
            provider: "apple",
            requestedLocale: language,
            message: message,
            progress: readiness == .ready ? 1 : 0
        )
    }

    public func startRecording(
        meetingID: Int,
        request: StartRecordingRequest
    ) async throws -> StartRecordingResponse {
        _ = try await meeting(id: meetingID)
        if let claim = recordingClaim {
            let apple = try settingsStore.envelope().document.transcription.local.apple ?? AppleSpeechSettings()
            if claim.meetingID == meetingID, claim.clientID == request.socketID {
                return StartRecordingResponse(
                    success: true,
                    language: claim.language,
                    engine: "apple",
                    generation: claim.generation,
                    provider: "apple",
                    model: "system",
                    mode: apple.mode,
                    preparedLocale: claim.language,
                    alreadyRecording: true
                )
            }
            throw NativeServiceError.server(status: 409, code: "RECORDING_ACTIVE", message: "Another recording is active.")
        }
        let initialDatabase = try requireDatabase()
        guard speechAssetPreparationLanguage == nil else {
            throw NativeServiceError.server(
                status: 409,
                code: "APPLE_SPEECH_PREPARATION_ACTIVE",
                message: "Wait for Speech asset installation to finish before recording."
            )
        }
        let startToken = UUID()
        recordingStartLanguages[startToken] = request.language
        defer { recordingStartLanguages.removeValue(forKey: startToken) }
        let preparation = await speechPreparation(language: request.language)
        guard preparation.state == "ready" else {
            throw NativeServiceError.server(
                status: 409,
                code: "APPLE_SPEECH_NOT_READY",
                message: preparation.message
            )
        }
        try Task.checkCancellation()
        if let claim = recordingClaim {
            let apple = try settingsStore.envelope().document.transcription.local.apple ?? AppleSpeechSettings()
            if claim.meetingID == meetingID, claim.clientID == request.socketID {
                return StartRecordingResponse(
                    success: true,
                    language: claim.language,
                    engine: "apple",
                    generation: claim.generation,
                    provider: "apple",
                    model: "system",
                    mode: apple.mode,
                    preparedLocale: claim.language,
                    alreadyRecording: true
                )
            }
            throw NativeServiceError.server(status: 409, code: "RECORDING_ACTIVE", message: "Another recording is active.")
        }
        guard databaseStorage === initialDatabase else {
            throw NativeServiceError.server(
                status: 409,
                code: "RECORDING_CONTEXT_CHANGED",
                message: "Settings changed while recording was starting. Try again."
            )
        }
        let apple = try settingsStore.envelope().document.transcription.local.apple ?? AppleSpeechSettings()
        let nextGeneration = recordingGeneration + 1
        let claim = NativeRecordingClaim(
            meetingID: meetingID,
            generation: nextGeneration,
            clientID: request.socketID,
            language: request.language,
            translationTarget: canonicalLanguage(request.translationTarget)
        )
        let update = try initialDatabase.run(
            "UPDATE meetings SET lang = ?, translate_to = ?, ended_at = NULL WHERE id = ?",
            [.text(request.language), .text(claim.translationTarget), .integer(Int64(meetingID))]
        )
        guard update.changes == 1 else {
            throw NativeServiceError.server(status: 404, code: "MEETING_NOT_FOUND", message: nil)
        }
        recordingGeneration = nextGeneration
        recordingClaim = claim
        return StartRecordingResponse(
            success: true,
            language: request.language,
            engine: "apple",
            generation: claim.generation,
            provider: "apple",
            model: "system",
            mode: apple.mode,
            preparedLocale: request.language,
            alreadyRecording: false
        )
    }

    public func finalizeRecording(_ request: FinalizeRecordingRequest) async throws -> SuccessResponse {
        guard let claim = recordingClaim else { return SuccessResponse(success: true) }
        guard claim.meetingID == request.meetingID,
              claim.generation == request.generation,
              claim.clientID == request.socketID || !connectedClientIDs.contains(claim.clientID) else {
            throw NativeServiceError.server(status: 409, code: "RECORDING_CLAIM_STALE", message: nil)
        }
        try Task.checkCancellation()
        try await recordingLifecycleObserver.beforeFinalizeRecording(request)
        try Task.checkCancellation()
        guard recordingClaim == claim else {
            throw NativeServiceError.server(status: 409, code: "RECORDING_CLAIM_STALE", message: nil)
        }
        _ = try requireDatabase().run(
            "UPDATE meetings SET ended_at = datetime('now') WHERE id = ?",
            [.integer(Int64(claim.meetingID))]
        )
        recordingClaim = nil
        return SuccessResponse(success: true)
    }

    func prepareRealtimeTranscription(
        _ request: StartTranscriptionRequest,
        clientID: String
    ) async throws -> ReadyForAudio {
        _ = try requireCurrentRecordingClaim(request, clientID: clientID)
        guard (1...2).contains(request.channelCount),
              request.sampleRate >= 8_000, request.sampleRate <= 192_000 else {
            throw NativeServiceError.server(status: 400, code: "AUDIO_FORMAT_INVALID", message: nil)
        }
        let selection = try settingsStore.envelope().document.transcription.local
        let apple = selection.apple ?? AppleSpeechSettings()
        try await speechService.prepare(
            language: request.language,
            mode: apple.mode,
            showDetails: apple.showDetails
        )
        return ReadyForAudio(
            engine: "apple",
            provider: "apple",
            model: "system",
            generation: request.generation
        )
    }

    func previewRealtimeTranscription(
        _ request: StartTranscriptionRequest,
        audio: Data,
        resultIDs: [String],
        clientID: String
    ) async throws -> [RealtimeMessage] {
        guard (try? requireCurrentRecordingClaim(request, clientID: clientID)) != nil else {
            return []
        }
        let apple = try settingsStore.envelope().document.transcription.local.apple ?? AppleSpeechSettings()
        guard apple.mode != "accurate" else { return [] }
        var messages: [RealtimeMessage] = []
        for channel in 0..<request.channelCount {
            let channelAudio = deinterleaved(audio, channelCount: request.channelCount, channel: channel)
            let result = try await transcribe(
                channelAudio,
                language: request.language,
                sampleRate: request.sampleRate,
                mode: "live",
                showDetails: apple.showDetails
            )
            try Task.checkCancellation()
            _ = try requireCurrentRecordingClaim(request, clientID: clientID)
            guard !NativeTranscriptNoise.isLikelyNoise(result.text) else { continue }
            let translation = await translateText(
                result.text,
                source: request.language,
                target: request.translationTarget
            )
            try Task.checkCancellation()
            _ = try requireCurrentRecordingClaim(request, clientID: clientID)
            let event = TranscriptionEvent(
                meetingID: request.meetingID,
                generation: request.generation,
                databaseID: nil,
                resultID: resultIDs.indices.contains(channel) ? resultIDs[channel] : "preview-\(channel)",
                transcript: result.text,
                isPartial: true,
                resultStage: "provisional",
                languageCode: request.language,
                speaker: nil,
                channelID: request.channelCount == 1 ? nil : "ch_\(channel)",
                alternatives: result.alternatives,
                confidence: result.confidence,
                transcriptionEngine: "apple",
                transcriptionProvider: "apple",
                transcriptionModel: "system",
                transcriptionMode: "live",
                translation: translation.text,
                translationTarget: canonicalLanguage(request.translationTarget),
                translationProvider: translation.provider,
                translationSourceHash: translation.sourceHash,
                translationSourceVersion: 1,
                translationStatus: translation.status,
                translationError: translation.error,
                translationAttempts: translation.status == .notRequired ? 0 : 1,
                translationUpdatedAt: ISO8601DateFormatter().string(from: Date())
            )
            messages.append(RealtimeMessage(name: .transcription, payload: try JSONEncoder().encode(event)))
        }
        return messages
    }

    func commitRealtimeChunk(
        _ request: StartTranscriptionRequest,
        audio: Data,
        resultIDs: [String],
        clientID: String
    ) async throws -> [RealtimeMessage] {
        _ = try requireCurrentRecordingClaim(request, clientID: clientID)
        let apple = try settingsStore.envelope().document.transcription.local.apple ?? AppleSpeechSettings()
        var messages: [RealtimeMessage] = []
        if !audio.isEmpty {
            for channel in 0..<request.channelCount {
                let channelAudio = deinterleaved(audio, channelCount: request.channelCount, channel: channel)
                let result = try await transcribe(
                    channelAudio,
                    language: request.language,
                    sampleRate: request.sampleRate,
                    mode: apple.mode,
                    showDetails: apple.showDetails
                )
                try Task.checkCancellation()
                _ = try requireCurrentRecordingClaim(request, clientID: clientID)
                guard !NativeTranscriptNoise.isLikelyNoise(result.text) else { continue }
                messages.append(try await persistTranscription(
                    result,
                    resultID: resultIDs.indices.contains(channel) ? resultIDs[channel] : UUID().uuidString,
                    request: request,
                    channel: request.channelCount == 1 ? nil : "ch_\(channel)",
                    mode: apple.mode,
                    clientID: clientID
                ))
            }
        }
        return messages
    }

    func finishRealtimeTranscription(
        _ request: StartTranscriptionRequest,
        audio: Data,
        resultIDs: [String],
        clientID: String
    ) async throws -> [RealtimeMessage] {
        let messages = try await commitRealtimeChunk(
            request,
            audio: audio,
            resultIDs: resultIDs,
            clientID: clientID
        )
        await recordingLifecycleObserver.beforeFinishClaimClear(request)
        try Task.checkCancellation()
        _ = try requireCurrentRecordingClaim(request, clientID: clientID)
        _ = try requireDatabase().run(
            "UPDATE meetings SET ended_at = datetime('now') WHERE id = ?",
            [.integer(Int64(request.meetingID))]
        )
        try clearRecordingClaimIfCurrent(request, clientID: clientID)
        return messages
    }

    private func transcribe(
        _ audio: Data,
        language: String,
        sampleRate: Double,
        mode: String,
        showDetails: Bool
    ) async throws -> NativeTranscriptionResult {
        try await speechService.transcribe(
            language: language,
            sampleRate: sampleRate,
            pcm: audio,
            mode: mode,
            showDetails: showDetails
        )
    }

    private func persistTranscription(
        _ result: NativeTranscriptionResult,
        resultID: String,
        request: StartTranscriptionRequest,
        channel: String?,
        mode: String,
        clientID: String
    ) async throws -> RealtimeMessage {
        let database = try requireDatabase()
        let alternatives = try encodeJSON(Array(result.alternatives.prefix(3)))
        let translation = await translateText(
            result.text,
            source: request.language,
            target: request.translationTarget
        )
        await recordingLifecycleObserver.beforeTranscriptInsert(request)
        try Task.checkCancellation()
        _ = try requireCurrentRecordingClaim(request, clientID: clientID)
        let target = canonicalLanguage(request.translationTarget)
        let updatedAt = ISO8601DateFormatter().string(from: Date())
        let insert = try database.run(
            """
            INSERT INTO transcripts (
              meeting_id, result_id, channel_id, text, translation,
              translation_target, translation_provider, translation_source_hash,
              translation_status, translation_error, translation_attempts,
              translation_updated_at, lang_code, alternatives, confidence,
              transcription_engine, transcription_provider, transcription_model,
              transcription_mode, result_stage
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'apple', 'apple', 'system', ?, 'final')
            """,
            [
                .integer(Int64(request.meetingID)), .text(resultID), optionalText(channel),
                .text(result.text), optionalText(translation.text), .text(target),
                optionalText(translation.provider), .text(translation.sourceHash),
                .text(translation.status.rawValue),
                translation.error.map { .text((try? encodeJSON($0)) ?? "") } ?? .null,
                .integer(translation.status == .notRequired ? 0 : 1), .text(updatedAt),
                .text(request.language), .text(alternatives),
                result.confidence.map(SQLiteValue.real) ?? .null, .text(mode),
            ]
        )
        let event = TranscriptionEvent(
            meetingID: request.meetingID,
            generation: request.generation,
            databaseID: insert.lastInsertID,
            resultID: resultID,
            transcript: result.text,
            isPartial: false,
            resultStage: "final",
            languageCode: request.language,
            speaker: nil,
            channelID: channel,
            alternatives: Array(result.alternatives.prefix(3)),
            confidence: result.confidence,
            transcriptionEngine: "apple",
            transcriptionProvider: "apple",
            transcriptionModel: "system",
            transcriptionMode: mode,
            translation: translation.text,
            translationTarget: target,
            translationProvider: translation.provider,
            translationSourceHash: translation.sourceHash,
            translationSourceVersion: 1,
            translationStatus: translation.status,
            translationError: translation.error,
            translationAttempts: translation.status == .notRequired ? 0 : 1,
            translationUpdatedAt: updatedAt
        )
        return RealtimeMessage(name: .transcription, payload: try JSONEncoder().encode(event))
    }

    @discardableResult
    private func requireCurrentRecordingClaim(
        _ request: StartTranscriptionRequest,
        clientID: String
    ) throws -> NativeRecordingClaim {
        guard let claim = recordingClaim,
              claim.meetingID == request.meetingID,
              claim.generation == request.generation,
              claim.clientID == clientID,
              claim.language == request.language,
              claim.translationTarget == canonicalLanguage(request.translationTarget) else {
            throw NativeServiceError.server(
                status: 409,
                code: "RECORDING_CLAIM_STALE",
                message: nil
            )
        }
        return claim
    }

    private func clearRecordingClaimIfCurrent(
        _ request: StartTranscriptionRequest,
        clientID: String
    ) throws {
        _ = try requireCurrentRecordingClaim(request, clientID: clientID)
        recordingClaim = nil
    }

    private func deinterleaved(_ data: Data, channelCount: Int, channel: Int) -> Data {
        guard channelCount > 1 else { return data }
        let frames = data.count / (2 * channelCount)
        var output = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let offset = (frame * channelCount + channel) * 2
            output.append(data[offset])
            output.append(data[offset + 1])
        }
        return output
    }
}
