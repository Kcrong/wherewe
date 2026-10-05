import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("In-process Apple service")
struct NativeServiceTests {
    @Test("setup transitions to ready with canonical Apple settings")
    func setupTransition() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)

        let initial = try await service.health()
        #expect(initial.state == .setupRequired)
        #expect(!initial.realtimeAvailable)
        let legacyPreparation = try JSONDecoder().decode(
            PrepareTranscriptionRequest.self,
            from: Data(#"{"provider":"apple","model":"system"}"#.utf8)
        )
        #expect(legacyPreparation.language == "en-US")
        let reservedLocales = [Locale(identifier: "ko-KR"), Locale(identifier: "en-US")]
        let releaseLocale = nativeSpeechReservationToRelease(
            targetLocale: Locale(identifier: "ja-JP"),
            reservedLocales: reservedLocales,
            maximumReservedLocales: 2
        )
        #expect(releaseLocale?.identifier(.bcp47) == "en-US")
        #expect(nativeSpeechReservationToRelease(
            targetLocale: Locale(identifier: "en-US"),
            reservedLocales: reservedLocales,
            maximumReservedLocales: 2
        ) == nil)
        #expect(nativeSpeechReservationToRelease(
            targetLocale: Locale(identifier: "ja-JP"),
            reservedLocales: reservedLocales,
            maximumReservedLocales: 3
        ) == nil)

        var request = try await service.settings().document.updateRequest
        request.user.name = "Native Tester"
        request.user.profile = "Validates the in-process service."
        request.transcription.engine = "retired"
        request.transcription.local.provider = "retired"
        request.transcription.local.model = "retired"
        request.translation.provider = "retired"
        let saved = try await service.updateSettings(request, etag: nil)

        #expect(saved.document.configured)
        #expect(saved.etag?.hasPrefix("\"settings-v1-") == true)
        #expect(saved.document.transcription.engine == "apple")
        #expect(saved.document.transcription.local.provider == "apple")
        #expect(saved.document.transcription.local.model == "system")
        #expect(saved.document.translation.provider == "apple")
        let catalogue = try await service.transcriptionCatalogue(language: "en-US")
        #expect(catalogue.localProviders.map(\.id) == ["apple"])
        #expect(catalogue.localProviders.first?.available == true)
        #expect(catalogue.localProviders.first?.ready == true)
        #expect(catalogue.progress.state == "ready")
        #expect(try await service.health().state == .ready)
        #expect(fixture.permissions(of: fixture.configURL) == 0o600)

        let missingAssetFixture = try Fixture()
        defer { missingAssetFixture.remove() }
        let missingAssetService = makeTestService(
            configuration: missingAssetFixture.configuration,
            speechReady: false
        )
        let missingAssetCatalogue = try await missingAssetService.transcriptionCatalogue(language: "en-US")
        #expect(missingAssetCatalogue.localProviders.first?.available == true)
        #expect(missingAssetCatalogue.localProviders.first?.ready == false)
        #expect(missingAssetCatalogue.progress.state == "installation-required")
        #expect(missingAssetCatalogue.progress.message == "Install English Speech assets before recording.")

        try await missingAssetFixture.configure(missingAssetService)
        let meeting = try await missingAssetService.createMeeting(CreateMeetingRequest(
            title: "Speech asset readiness",
            language: "en-US",
            translationTarget: "ko"
        ))
        do {
            _ = try await missingAssetService.startRecording(
                meetingID: meeting.id,
                request: StartRecordingRequest(
                    socketID: "speech-readiness-client",
                    language: "en-US",
                    translationTarget: "ko"
                )
            )
            Issue.record("recording must not claim state before Speech assets are ready")
        } catch let error as NativeServiceError {
            #expect(error == .server(
                status: 409,
                code: "APPLE_SPEECH_NOT_READY",
                message: "Install English Speech assets in Settings before recording."
            ))
        }
        #expect(try await !missingAssetService.recordingStatus(socketID: nil).selectionLocked)

        let koreanCatalogue = try await missingAssetService.prepareTranscription(
            provider: "apple",
            model: "system",
            language: "ko-KR"
        )
        #expect(koreanCatalogue.localProviders.first?.ready == true)
        #expect(try await missingAssetService.transcriptionCatalogue(language: "en-US").progress.state == "installation-required")

        let installedCatalogue = try await missingAssetService.prepareTranscription(
            provider: "apple",
            model: "system",
            language: "en-US"
        )
        #expect(installedCatalogue.localProviders.first?.ready == true)
        let started = try await missingAssetService.startRecording(
            meetingID: meeting.id,
            request: StartRecordingRequest(
                socketID: "speech-readiness-client",
                language: "en-US",
                translationTarget: "ko"
            )
        )
        #expect(started.preparedLocale == "en-US")
        do {
            _ = try await missingAssetService.prepareTranscription(
                provider: "apple",
                model: "system",
                language: "ko-KR"
            )
            Issue.record("installing another Speech locale must be rejected during recording")
        } catch let error as NativeServiceError {
            #expect(error == .server(
                status: 409,
                code: "APPLE_SPEECH_PREPARATION_ACTIVE",
                message: "Wait for recording startup or recording to finish before installing Speech assets."
            ))
        }
        _ = try await missingAssetService.finalizeRecording(FinalizeRecordingRequest(
            meetingID: meeting.id,
            generation: started.generation,
            socketID: "speech-readiness-client"
        ))

        let preparationFixture = try Fixture()
        defer { preparationFixture.remove() }
        let preparationGate = SuspendedSpeechReadinessGate()
        let preparationService = NativeService(
            configuration: preparationFixture.configuration,
            eventHub: NativeRealtimeHub(),
            speechService: SuspendedPrepareSpeechService(gate: preparationGate),
            translationService: DeterministicTranslationService()
        )
        try await preparationFixture.configure(preparationService)
        let preparationMeeting = try await preparationService.createMeeting(CreateMeetingRequest(
            title: "Preparation serialization",
            language: "en-US",
            translationTarget: "ko"
        ))
        let preparationTask = Task {
            try await preparationService.prepareTranscription(
                provider: "apple",
                model: "system",
                language: "ko-KR"
            )
        }
        do {
            try await preparationGate.waitUntilRequests(1)
        } catch {
            preparationTask.cancel()
            await preparationGate.releaseAll()
            throw error
        }
        do {
            _ = try await preparationService.startRecording(
                meetingID: preparationMeeting.id,
                request: StartRecordingRequest(
                    socketID: "preparation-serialization-client",
                    language: "en-US",
                    translationTarget: "ko"
                )
            )
            Issue.record("recording must not start while Speech reservations are changing")
        } catch let error as NativeServiceError {
            #expect(error == .server(
                status: 409,
                code: "APPLE_SPEECH_PREPARATION_ACTIVE",
                message: "Wait for Speech asset installation to finish before recording."
            ))
        }
        #expect(try await !preparationService.recordingStatus(socketID: nil).selectionLocked)
        await preparationGate.releaseAll()
        #expect(try await preparationTask.value.localProviders.first?.ready == true)
    }

    @Test("concurrent starts create one claim after readiness suspension")
    func concurrentRecordingStarts() async throws {
        let blockedFixture = try Fixture()
        defer { blockedFixture.remove() }
        let blockedGate = SuspendedSpeechReadinessGate()
        let blockedService = NativeService(
            configuration: blockedFixture.configuration,
            eventHub: NativeRealtimeHub(),
            speechService: SuspendedReadySpeechService(gate: blockedGate),
            translationService: DeterministicTranslationService()
        )
        try await blockedFixture.configure(blockedService)
        let originalMeeting = try await blockedService.createMeeting(CreateMeetingRequest(
            title: "Original database meeting",
            language: "en-US",
            translationTarget: "ko"
        ))
        let blockedStart = Task {
            try await blockedService.startRecording(
                meetingID: originalMeeting.id,
                request: StartRecordingRequest(
                    socketID: "blocked-settings-client",
                    language: "ja-JP",
                    translationTarget: "en"
                )
            )
        }
        do {
            try await blockedGate.waitUntilRequests(1)
        } catch {
            blockedStart.cancel()
            await blockedGate.releaseAll()
            throw error
        }
        let currentSettings = try await blockedService.settings()
        var replacement = currentSettings.document.updateRequest
        let replacementRoot = blockedFixture.root.appendingPathComponent("replacement", isDirectory: true)
        let replacementData = replacementRoot.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementData, withIntermediateDirectories: true)
        let corruptDatabase = replacementData.appendingPathComponent("meetings.db")
        try Data("not-a-sqlite-database".utf8).write(to: corruptDatabase)
        replacement.paths.database = corruptDatabase.path
        replacement.paths.files = replacementData.appendingPathComponent("files", isDirectory: true).path
        do {
            _ = try await blockedService.updateSettings(replacement, etag: currentSettings.etag)
            Issue.record("settings update must be rejected while recording startup is pending")
        } catch let error as NativeServiceError {
            #expect(error == .server(
                status: 409,
                code: "SETTINGS_TRANSCRIPTION_ACTIVE",
                message: "Wait for recording startup to finish before changing settings."
            ))
        }
        do {
            _ = try await blockedService.importSettings(
                JSONEncoder().encode(replacement),
                etag: currentSettings.etag
            )
            Issue.record("settings import must be rejected while recording startup is pending")
        } catch let error as NativeServiceError {
            #expect(error == .server(
                status: 409,
                code: "SETTINGS_TRANSCRIPTION_ACTIVE",
                message: "Stop recording or wait for recording startup to finish before importing settings."
            ))
        }
        #expect(try await blockedService.settings().document.paths.database == blockedFixture.databaseURL.path)
        await blockedGate.releaseAll()
        let blockedStarted = try await blockedStart.value
        #expect(blockedStarted.preparedLocale == "ja-JP")
        #expect(try await blockedService.meeting(id: originalMeeting.id).language == "ja-JP")
        _ = try await blockedService.finalizeRecording(FinalizeRecordingRequest(
            meetingID: originalMeeting.id,
            generation: blockedStarted.generation,
            socketID: "blocked-settings-client"
        ))

        let deletedFixture = try Fixture()
        defer { deletedFixture.remove() }
        let deletedGate = SuspendedSpeechReadinessGate()
        let deletedService = NativeService(
            configuration: deletedFixture.configuration,
            eventHub: NativeRealtimeHub(),
            speechService: SuspendedReadySpeechService(gate: deletedGate),
            translationService: DeterministicTranslationService()
        )
        try await deletedFixture.configure(deletedService)
        let deletedMeeting = try await deletedService.createMeeting(CreateMeetingRequest(
            title: "Deleted during readiness",
            language: "en-US",
            translationTarget: "ko"
        ))
        let deletedStart = Task {
            try await deletedService.startRecording(
                meetingID: deletedMeeting.id,
                request: StartRecordingRequest(
                    socketID: "deleted-readiness-client",
                    language: "en-US",
                    translationTarget: "ko"
                )
            )
        }
        do {
            try await deletedGate.waitUntilRequests(1)
        } catch {
            deletedStart.cancel()
            await deletedGate.releaseAll()
            throw error
        }
        do {
            _ = try await deletedService.prepareTranscription(
                provider: "apple",
                model: "system",
                language: "ko-KR"
            )
            Issue.record("Speech reservations must not change while recording startup is pending")
        } catch let error as NativeServiceError {
            #expect(error == .server(
                status: 409,
                code: "APPLE_SPEECH_PREPARATION_ACTIVE",
                message: "Wait for recording startup or recording to finish before installing Speech assets."
            ))
        }
        _ = try await deletedService.deleteMeeting(id: deletedMeeting.id, socketID: nil)
        await deletedGate.releaseAll()
        await #expect(throws: NativeServiceError.self) {
            _ = try await deletedStart.value
        }
        let deletedStatus = try await deletedService.recordingStatus(socketID: nil)
        #expect(!deletedStatus.selectionLocked)
        #expect(deletedStatus.recordingGeneration == nil)

        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = SuspendedSpeechReadinessGate()
        let service = NativeService(
            configuration: fixture.configuration,
            eventHub: NativeRealtimeHub(),
            speechService: SuspendedReadySpeechService(gate: gate),
            translationService: DeterministicTranslationService()
        )
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(
            title: "Concurrent readiness",
            language: "en-US",
            translationTarget: "ko"
        ))
        let first = Task { () throws -> (socketID: String, response: StartRecordingResponse) in
            let socketID = "readiness-client-one"
            let response = try await service.startRecording(
                meetingID: meeting.id,
                request: StartRecordingRequest(
                    socketID: socketID,
                    language: "en-US",
                    translationTarget: "ko"
                )
            )
            return (socketID, response)
        }
        let second = Task { () throws -> (socketID: String, response: StartRecordingResponse) in
            let socketID = "readiness-client-two"
            let response = try await service.startRecording(
                meetingID: meeting.id,
                request: StartRecordingRequest(
                    socketID: socketID,
                    language: "en-US",
                    translationTarget: "ko"
                )
            )
            return (socketID, response)
        }

        do {
            try await gate.waitUntilRequests(2)
        } catch {
            first.cancel()
            second.cancel()
            await gate.releaseAll()
            throw error
        }
        await gate.releaseAll()
        var successes: [(socketID: String, response: StartRecordingResponse)] = []
        var failures: [Error] = []
        for task in [first, second] {
            do { successes.append(try await task.value) }
            catch { failures.append(error) }
        }
        #expect(successes.count == 1)
        #expect(failures.count == 1)
        if let failure = failures.first as? NativeServiceError {
            #expect(failure == .server(
                status: 409,
                code: "RECORDING_ACTIVE",
                message: "Another recording is active."
            ))
        } else {
            Issue.record("concurrent start loser must report RECORDING_ACTIVE")
        }
        let started = try #require(successes.first)
        let status = try await service.recordingStatus(socketID: started.socketID)
        #expect(status.selectionLocked)
        #expect(status.recordingOwnedByRequester)
        #expect(status.recordingGeneration == started.response.generation)
        _ = try await service.finalizeRecording(FinalizeRecordingRequest(
            meetingID: meeting.id,
            generation: started.response.generation,
            socketID: started.socketID
        ))
    }

    @Test("legacy settings import keeps paths and normalizes retired selections")
    func legacySettingsNormalization() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        let object: [String: Any] = [
            "version": 1,
            "transcription": [
                "engine": "legacy",
                "local": ["provider": "legacy", "model": "legacy", "apple": NSNull()],
            ],
            "translation": ["provider": "legacy"],
            "user": [
                "name": "Import Tester",
                "role": "",
                "organization": "",
                "profile": "Validates compatibility normalization.",
            ],
            "paths": [
                "database": fixture.databaseURL.path,
                "files": fixture.filesURL.path,
                "obsoleteOutput": fixture.root.appendingPathComponent("obsolete").path,
            ],
            "obsoleteModels": ["summary": "legacy"],
        ]
        let imported = try await service.importSettings(
            JSONSerialization.data(withJSONObject: object),
            etag: nil
        )

        #expect(imported.document.transcription.engine == "apple")
        #expect(imported.document.transcription.local.provider == "apple")
        #expect(imported.document.transcription.local.model == "system")
        #expect(imported.document.transcription.local.apple == AppleSpeechSettings())
        #expect(imported.document.translation.provider == "apple")
        #expect(imported.document.paths.database == fixture.databaseURL.path)
        #expect(imported.document.paths.files == fixture.filesURL.path)
    }

    @Test("meeting CRUD persists across service restart")
    func meetingPersistence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var service: NativeService? = makeTestService(configuration: fixture.configuration)
        try await fixture.configure(service!)

        let created = try await service!.createMeeting(CreateMeetingRequest(
            title: "Wherewe workflow",
            context: "Preserve the contract",
            language: "en-US",
            translationTarget: "ko"
        ))
        _ = try await service!.updateMeeting(
            id: created.id,
            request: UpdateMeetingRequest(title: "Wherewe workflow review", context: "Updated")
        )
        #expect(try await service!.meeting(id: created.id).title == "Wherewe workflow review")
        service = nil

        let restarted = makeTestService(configuration: fixture.configuration)
        #expect(try await restarted.meetings().map(\.id) == [created.id])
        #expect(try await restarted.meeting(id: created.id).context == "Updated")
        #expect(fixture.permissions(of: fixture.databaseURL) == 0o600)
        #expect(fixture.permissions(of: fixture.databaseCompanionURL("-wal")) == 0o600)
        #expect(fixture.permissions(of: fixture.databaseCompanionURL("-shm")) == 0o600)

        _ = try await restarted.deleteMeeting(id: created.id, socketID: nil)
        #expect(try await restarted.meetings().isEmpty)
    }

    @Test("invalid database changes keep saved settings and the active database")
    func invalidDatabaseSettingsChanges() async throws {
        func verify(importing: Bool) async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let service = makeTestService(configuration: fixture.configuration)
            try await fixture.configure(service)
            let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Original database meeting"))
            let original = try await service.settings()
            let savedData = try Data(contentsOf: fixture.configURL)

            let replacementRoot = fixture.root.appendingPathComponent(
                importing ? "invalid-import" : "invalid-update",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: true)
            let invalidDatabase = replacementRoot.appendingPathComponent("meetings.db")
            try Data("not-a-sqlite-database".utf8).write(to: invalidDatabase)
            var replacement = original.document.updateRequest
            replacement.paths.database = invalidDatabase.path
            replacement.paths.files = replacementRoot.appendingPathComponent("files", isDirectory: true).path

            await #expect(throws: NativeSQLiteError.self) {
                if importing {
                    _ = try await service.importSettings(
                        JSONEncoder().encode(replacement),
                        etag: original.etag
                    )
                } else {
                    _ = try await service.updateSettings(replacement, etag: original.etag)
                }
            }

            #expect(try Data(contentsOf: fixture.configURL) == savedData)
            #expect(try await service.settings() == original)
            #expect(try await service.meetings().map(\.id) == [meeting.id])
            let restarted = makeTestService(configuration: fixture.configuration)
            #expect(try await restarted.health().state == .ready)
            #expect(try await restarted.meetings().map(\.id) == [meeting.id])
        }

        try await verify(importing: false)
        try await verify(importing: true)
    }

    @Test("stale settings ETag is rejected")
    func staleSettingsRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        try await fixture.configure(service)
        var request = try await service.settings().document.updateRequest
        request.user.role = "Engineer"

        await #expect(throws: NativeServiceError.self) {
            _ = try await service.updateSettings(request, etag: "\"settings-v1-stale\"")
        }
    }

    @Test("attachments glossary and export stay local and secure")
    func workspacePersistenceAndExport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(
            title: "Workspace review",
            context: "Local-only evidence",
            language: "en-US",
            translationTarget: "ko"
        ))

        let payload = Data("native document".utf8)
        let upload = try await service.uploadDocument(meetingID: meeting.id, name: "검토.txt", data: payload)
        #expect(try await service.documents(meetingID: meeting.id).first?.name == "검토.txt")
        #expect(try await service.documentContent(id: upload.id).data == payload)

        let term = try await service.createGlossary(GlossaryMutationRequest(
            phrase: "release gate",
            displayAs: "release gate",
            language: "en"
        ))
        let unrelatedTerm = try await service.createGlossary(GlossaryMutationRequest(
            phrase: "出荷判定",
            displayAs: nil,
            language: "ja"
        ))
        #expect(try await service.glossary(language: "en").map(\.id) == [term.id])

        let exported = try await service.exportMeeting(id: meeting.id)
        let root = URL(fileURLWithPath: exported.path, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("meeting.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("transcript.md").path))
        let backgroundURL = root.appendingPathComponent("background/context.md")
        #expect(FileManager.default.fileExists(atPath: backgroundURL.path))
        let background = String(decoding: try Data(contentsOf: backgroundURL), as: UTF8.self)
        #expect(background.contains("## Glossary"))
        #expect(background.contains("**release gate** → release gate _[en]_"))
        #expect(!background.contains("出荷判定"))
        #expect(exported.counts.glossary == 1)
        #expect(exported.files.attachments == ["background/files/검토.txt"])
        #expect(try await service.reveal(path: exported.path).success)

        #expect(try await service.deleteDocument(id: upload.id).success)
        #expect(try await service.deleteGlossary(id: term.id).success)
        #expect(try await service.deleteGlossary(id: unrelatedTerm.id).success)
    }

    @Test("recording persists Apple transcription and translation metadata")
    func nativeRecordingRoundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Native recording"))
        let realtime = NativeRealtimeClient(service: service)
        let coordinator = RecordingCoordinator(api: service, realtime: realtime, readyTimeout: .seconds(2))

        let claim = try await coordinator.start(
            meetingID: meeting.id,
            language: "en-US",
            translationTarget: "ko",
            sampleRate: 16_000,
            channelCount: 1
        )
        #expect(claim.meetingID == meeting.id)
        try await coordinator.sendPCM([Int16](repeating: 1, count: 1_600))
        #expect(try await coordinator.stop().audioDeliveryConfirmed)

        let restored = try await service.meeting(id: meeting.id)
        #expect(restored.transcripts.count == 1)
        #expect(restored.transcripts[0].text == "Hello world from deterministic speech.")
        #expect(restored.transcripts[0].transcriptionEngine == "apple")
        #expect(restored.transcripts[0].transcriptionProvider == "apple")
        #expect(restored.transcripts[0].transcriptionModel == "system")
        #expect(restored.transcripts[0].translation == "Translated: Hello world from deterministic speech.")
        #expect(restored.transcripts[0].translationProvider == "apple")
        #expect(restored.transcripts[0].translationStatus == .succeeded)
        await coordinator.close()
    }

    @Test("recorded raw transcript can be edited through one upserted segment")
    func manualSegmentEditing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Manual edit"))
        let realtime = NativeRealtimeClient(service: service)
        let coordinator = RecordingCoordinator(api: service, realtime: realtime, readyTimeout: .seconds(2))
        _ = try await coordinator.start(
            meetingID: meeting.id,
            language: "en-US",
            translationTarget: "ko",
            sampleRate: 16_000,
            channelCount: 1
        )
        try await coordinator.sendPCM([Int16](repeating: 1, count: 1_600))
        _ = try await coordinator.stop()

        let raw = try #require(try await service.meeting(id: meeting.id).transcripts.first)
        let first = try await service.editTranscript(
            meetingID: meeting.id,
            transcriptID: raw.id,
            text: "Edited once"
        )
        #expect(first.segment.text == "Edited once")
        #expect(first.segment.sourceIDs == [raw.resultID ?? "db:\(raw.id)"])
        #expect(first.segment.corrections.last == SegmentCorrection(
            from: "Hello world from deterministic speech.",
            to: "Edited once",
            reason: "manual"
        ))
        #expect(first.segment.translation == "Translated: Edited once")
        #expect(first.segment.translationProvider == "apple")
        #expect(first.segment.translationStatus == .succeeded)

        let second = try await service.editTranscript(
            meetingID: meeting.id,
            transcriptID: raw.id,
            text: "Edited twice"
        )
        let detail = try await service.meeting(id: meeting.id)
        #expect(detail.segments.count == 1)
        #expect(second.segment.id == first.segment.id)
        #expect(second.segment.text == "Edited twice")
        #expect(second.segment.translation == "Translated: Edited twice")
        await coordinator.close()
    }

    @Test("editing middle transcript preserves display order")
    func editedMiddleTranscriptDisplayOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Ordered display"))
        let transcriptIDs = try fixture.insertTranscripts(
            meetingID: meeting.id,
            texts: ["First raw", "Middle raw", "Last raw"]
        )

        _ = try await service.editTranscript(
            meetingID: meeting.id,
            transcriptID: transcriptIDs[1],
            text: "Edited middle"
        )
        let store = TranscriptStore()
        _ = await store.activate(try await service.meeting(id: meeting.id))
        let visibleText = await store.visibleItems(view: .edited).map { item in
            switch item {
            case let .segment(segment): segment.text
            case let .transcript(row): row.text
            case let .partial(row): row.text
            }
        }

        #expect(visibleText == ["First raw", "Edited middle", "Last raw"])
    }

    @Test("editing middle transcript preserves export order")
    func editedMiddleTranscriptExportOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Ordered export"))
        let transcriptIDs = try fixture.insertTranscripts(
            meetingID: meeting.id,
            texts: ["First raw", "Middle raw", "Last raw"]
        )

        _ = try await service.editTranscript(
            meetingID: meeting.id,
            transcriptID: transcriptIDs[1],
            text: "Edited middle"
        )
        let exported = try await service.exportMeeting(id: meeting.id)
        let transcriptURL = URL(fileURLWithPath: exported.path).appendingPathComponent("transcript.md")
        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
        let first = try #require(transcript.range(of: "First raw"))
        let middle = try #require(transcript.range(of: "Edited middle"))
        let last = try #require(transcript.range(of: "Last raw"))

        #expect(first.lowerBound < middle.lowerBound)
        #expect(middle.lowerBound < last.lowerBound)
        #expect(!transcript.contains("Middle raw"))
    }

    @Test("long recording commits bounded chunks before stop")
    func boundedRecordingChunks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Chunked recording"))
        let realtime = NativeRealtimeClient(service: service)
        let coordinator = RecordingCoordinator(api: service, realtime: realtime, readyTimeout: .seconds(2))
        _ = try await coordinator.start(
            meetingID: meeting.id,
            language: "en-US",
            translationTarget: "ko",
            sampleRate: 8_000,
            channelCount: 1
        )
        for _ in 0..<110 {
            try await coordinator.sendPCM([Int16](repeating: 1, count: 800))
            try await Task.sleep(for: .milliseconds(2))
        }
        _ = try await coordinator.stop()
        let transcripts = try await service.meeting(id: meeting.id).transcripts
        #expect(transcripts.count == 2)
        #expect(Set(transcripts.compactMap(\.resultID)).count == 2)
        await coordinator.close()
    }

    @Test("corrupt settings are reported through health without terminating startup")
    func corruptSettingsStartupFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("{not-valid-json".utf8).write(to: fixture.configURL)

        let service = makeTestService(configuration: fixture.configuration)
        await #expect(throws: NativeServiceError.server(
            status: 500,
            code: "SETTINGS_UNAVAILABLE",
            message: "The settings file is unavailable."
        )) {
            _ = try await service.health()
        }
    }

    @Test("corrupt database is reported through health without terminating startup")
    func corruptDatabaseStartupFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let settingsStore = NativeSettingsStore(configuration: fixture.configuration)
        var request = settingsStore.initialDocument().updateRequest
        request.user.name = "Native Tester"
        request.user.profile = "Validates startup error handling."
        _ = try settingsStore.update(request, etag: nil)
        try Data("not-a-sqlite-database".utf8).write(to: fixture.databaseURL)

        let service = makeTestService(configuration: fixture.configuration)
        await #expect(throws: NativeSQLiteError.self) {
            _ = try await service.health()
        }
    }
}

private struct Fixture {
    let root: URL
    let configURL: URL
    let configuration: NativeServiceConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-service-tests-\(UUID().uuidString)", isDirectory: true)
        configURL = root.appendingPathComponent("config.json")
        configuration = NativeServiceConfiguration(
            configURL: configURL,
            defaultDataRoot: root,
            applicationVersion: "test",
            environment: [
                "WHEREWE_SUPPRESS_OPEN": "1",
            ]
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var databaseURL: URL { root.appendingPathComponent("data/meetings.db") }
    var filesURL: URL { root.appendingPathComponent("data/files", isDirectory: true) }

    func insertTranscripts(meetingID: Int, texts: [String]) throws -> [Int] {
        let database = try NativeDatabase(url: databaseURL)
        return try texts.enumerated().map { index, text in
            let timestamp = String(format: "2026-10-05T07:00:%02dZ", index)
            return try database.run(
                """
                INSERT INTO transcripts (meeting_id, result_id, text, created_at)
                VALUES (?, ?, ?, ?)
                """,
                [
                    .integer(Int64(meetingID)), .text("ordered-\(index)"),
                    .text(text), .text(timestamp),
                ]
            ).lastInsertID
        }
    }

    func databaseCompanionURL(_ suffix: String) -> URL {
        URL(fileURLWithPath: databaseURL.path + suffix)
    }

    func configure(_ service: NativeService) async throws {
        var request = try await service.settings().document.updateRequest
        request.user.name = "Native Tester"
        request.user.profile = "Validates persistence."
        _ = try await service.updateSettings(request, etag: nil)
    }

    func permissions(of url: URL) -> Int? {
        let value = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return (value as? NSNumber)?.intValue
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
