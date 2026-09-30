import XCTest
@testable import Mocca

private final class CompletionRecoveryInput: @unchecked Sendable {
    let snapshot: ConversationSnapshot
    let directory: URL
    init(_ snapshot: ConversationSnapshot, _ directory: URL) {
        self.snapshot = snapshot; self.directory = directory
    }
}

private final class CompletionRecoveryOutput: @unchecked Sendable {
    let snapshot: ConversationSnapshot
    let report: PendingGenerationCompletionJournal.RecoveryReport
    init(_ snapshot: ConversationSnapshot, _ report: PendingGenerationCompletionJournal.RecoveryReport) {
        self.snapshot = snapshot; self.report = report
    }
}

@MainActor final class CompletionWorkTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func fixture(count: Int = 8) throws -> (AppModel, ConversationSnapshot, URL) {
        let model = AppModel(), dir = try directory()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let chat = Conversation(title: "Synthetic", createdAt: date, updatedAt: date)
        let rows = (0..<count).map { ChatMessage(conversationID: chat.id, role: .user,
            text: "row \($0)", createdAt: date, updatedAt: date) }
        let snapshot = ConversationSnapshot(conversations: [chat], messagesByConversation: [chat.id: rows])
        try model.completionInstall(snapshot, directory: dir)
        return (model, snapshot, dir)
    }
    private func load(_ directory: URL) throws -> ConversationSnapshot {
        switch try ConversationStore(directoryURL: directory).load() {
        case .loaded(let value), .recoveredFromBackup(let value, _): return value
        case .missing: throw NSError(domain: "missing synthetic store", code: 1)
        }
    }
    private func waitForSubmission(_ key: String = "submissions") async {
        for _ in 0..<1000 {
            if CompletionWorkProbe.shared.sample()[key, default: 0] > 0 { return }
            await Task.yield()
        }
        XCTFail("Request was not submitted: \(key)")
    }
    private func waitForGate(_ gate: CompletionWorkGate) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if gate.consumeEntry() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Synthetic worker gate was not entered")
    }
    private func message(_ chat: UUID, text: String = "completed") -> ChatMessage {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return ChatMessage(conversationID: chat, role: .assistant, text: text, createdAt: date, updatedAt: date)
    }
    private func enqueue(_ writer: PendingGenerationCompletionJournal.Writer, _ value: ChatMessage) async throws {
        let result = await withCheckedContinuation { continuation in
            writer.enqueueCompletedMessage(value) { continuation.resume(returning: $0) }
        }
        try result.get()
    }
    private func recover(_ snapshot: ConversationSnapshot, from directory: URL) async -> CompletionRecoveryOutput {
        let input = CompletionRecoveryInput(snapshot, directory)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var value = input.snapshot
                CompletionWorkProbe.shared.record("recoveryStarts")
                let report = PendingGenerationCompletionJournal.mergeRecoverableCompletions(into: &value, directoryURL: input.directory)
                CompletionWorkProbe.shared.record("recoveryFinishes")
                continuation.resume(returning: CompletionRecoveryOutput(value, report))
            }
        }
    }
    func testAsyncSaveCapturesIdentityOffMainAndKeepsUIAvailable() async throws {
        let (model, original, dir) = try fixture(count: 5000)
        let gate = CompletionWorkGate(); model.completionHoldQueue(gate)
        await waitForGate(gate)
        CompletionWorkProbe.shared.reset()
        let task = Task { await model.completionSave() }
        await waitForSubmission()
        model.isDrawerPresented = true
        XCTAssertEqual(CompletionWorkProbe.shared.sample()["identityCaptures", default: 0], 0)
        gate.release.signal()
        let outcome = await task.value
        XCTAssertEqual(outcome, "committed")
        let sample = CompletionWorkProbe.shared.sample()
        XCTAssertEqual(sample["identityCaptures"], 1)
        XCTAssertEqual(sample["mainIdentityCaptures", default: 0], 0)
        XCTAssertTrue(model.isDrawerPresented)
        XCTAssertEqual(try load(dir).messagesByConversation, original.messagesByConversation)
        print("COMPLETION_IDENTITY_PROOF " + String(decoding: try JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]), as: UTF8.self))
    }
    func testUnauthorizedRemovalAndSameCountReplacementNeverReachDisk() async throws {
        for replacement in [false, true] {
            let (model, original, dir) = try fixture()
            var changed = original; let id = original.conversations[0].id
            if replacement { changed.messagesByConversation[id]![0] = message(id, text: "wrong identity") }
            else { changed.messagesByConversation[id]!.removeLast() }
            model.completionReplace(changed)
            let outcome = await model.completionSave()
            XCTAssertEqual(outcome, "failed")
            XCTAssertFalse(model.completionReady)
            XCTAssertEqual(try load(dir).messagesByConversation, original.messagesByConversation)
        }
    }
    func testSeparateReductionPermissionsAndAuthorizedDeletion() async throws {
        for allowMessages in [false, true] {
            let (model, original, dir) = try fixture()
            var changed = original; changed.messagesByConversation[original.conversations[0].id]!.removeLast()
            model.completionReplace(changed)
            let outcome = await model.completionSave(conversations: true, messages: allowMessages)
            XCTAssertEqual(outcome, allowMessages ? "committed" : "failed")
            XCTAssertEqual(try load(dir).messagesByConversation, allowMessages ? changed.messagesByConversation : original.messagesByConversation)
        }
    }
    func testQueuedSaveThenSynchronousSaveCannotRollMetadataBack() async throws {
        let (model, original, dir) = try fixture(), id = original.conversations[0].id
        let gate = CompletionWorkGate(); model.completionHoldQueue(gate)
        await waitForGate(gate)
        CompletionWorkProbe.shared.reset()
        let first = Task { await model.completionSave() }
        await waitForSubmission()
        var later = original; later.messagesByConversation[id]!.append(message(id, text: "later"))
        model.completionReplace(later); gate.release.signal()
        XCTAssertTrue(model.completionSaveSynchronously())
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, "superseded")
        XCTAssertEqual(model.completionPersistedIDs, Set(later.messagesByConversation[id]!.map(\.id)))
        XCTAssertEqual(try load(dir).messagesByConversation, later.messagesByConversation)
    }
    func testReloadEpochRejectsOldCompletionAndFailureStaysBlocked() async throws {
        let (model, original, dir) = try fixture()
        let gate = CompletionWorkGate(); model.completionHoldQueue(gate)
        await waitForGate(gate)
        CompletionWorkProbe.shared.reset()
        let old = Task { await model.completionSave() }; await waitForSubmission()
        model.completionAdvanceEpoch(); gate.release.signal()
        let oldOutcome = await old.value
        XCTAssertEqual(oldOutcome, "superseded")
        model.completionFailCommits(true)
        let failed = await model.completionSave()
        XCTAssertEqual(failed, "failed"); XCTAssertFalse(model.completionReady)
        XCTAssertEqual(try load(dir).messagesByConversation, original.messagesByConversation)
    }
    func testEmptyDraftOmissionAndPopulatedDraftStillPersist() throws {
        let (model, original, _) = try fixture()
        XCTAssertEqual(model.persistableConversationSnapshot().messagesByConversation, original.messagesByConversation)
        var data = original; let draft = Conversation(title: "Draft")
        data.conversations.append(draft); data.messagesByConversation[draft.id] = []
        model.completionReplace(data); model.completionMarkDraft(draft.id)
        XCTAssertFalse(model.persistableConversationSnapshot().conversations.contains { $0.id == draft.id })
        data.messagesByConversation[draft.id] = [message(draft.id)]
        model.completionReplace(data)
        XCTAssertTrue(model.persistableConversationSnapshot().conversations.contains { $0.id == draft.id })
    }
    func testJournalDeduplicatesWholeValueAndChangedMetadataStillWrites() async throws {
        let dir = try directory(), chat = UUID(); var value = message(chat, text: String(repeating: "long 中文 ", count: 4000))
        let writer = try PendingGenerationCompletionJournal.makeWriter(runID: value.id, conversationID: chat, directoryURL: dir)
        CompletionWorkProbe.shared.reset()
        try await enqueue(writer, value); try await enqueue(writer, value)
        XCTAssertEqual(CompletionWorkProbe.shared.sample()["journalWrites"], 1)
        XCTAssertEqual(CompletionWorkProbe.shared.sample()["mainJournalWrites", default: 0], 0)
        value.translation = "metadata changed"
        try await enqueue(writer, value)
        XCTAssertEqual(CompletionWorkProbe.shared.sample()["journalWrites"], 2)
        value.attachments = [MessageAttachment(kind: .image,
            remoteURL: URL(string: "https://example.invalid/generated.png"), mimeType: "image/png")]
        try await enqueue(writer, value)
        XCTAssertEqual(CompletionWorkProbe.shared.sample()["journalWrites"], 3)
        writer.closeKeepingFile()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(PendingGenerationCompletionRecord.self, from: Data(contentsOf: writer.fileURL)).message, value)
        do { try await enqueue(writer, value); XCTFail("Closed writer accepted a cached value") } catch {}
    }
    func testFailedReplacementInvalidatesPreviouslyDurableJournalCache() async throws {
        let chat = UUID(), original = message(UUID())
        let value = ChatMessage(id: original.id, conversationID: chat, role: .assistant,
            text: "previous durable reply", createdAt: original.createdAt, updatedAt: original.updatedAt)
        let writer = try PendingGenerationCompletionJournal.makeWriter(runID: value.id, conversationID: chat, directoryURL: directory())
        CompletionWorkProbe.shared.reset()
        try await enqueue(writer, value)
        writer.completionFailNextWrite()
        var replacement = value; replacement.translation = "different value"
        do { try await enqueue(writer, replacement); XCTFail("Injected truncated write did not fail") } catch {}
        XCTAssertEqual(try Data(contentsOf: writer.fileURL).count, 0)
        try await enqueue(writer, value)
        XCTAssertEqual(CompletionWorkProbe.shared.sample()["journalWrites"], 2)
        writer.closeKeepingFile()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(PendingGenerationCompletionRecord.self, from: Data(contentsOf: writer.fileURL)).message, value)
    }
    func testRecoveryWaitsForInFlightJournalInsteadOfReadingTruncatedFile() async throws {
        let (_, initial, _) = try fixture(), chat = initial.conversations[0].id
        let dir = try directory(), value = message(chat, text: "recover the entire finished reply")
        let writer = try PendingGenerationCompletionJournal.makeWriter(runID: value.id, conversationID: chat, directoryURL: dir)
        let gate = CompletionWorkGate(); writer.completionHoldNextTruncate(gate)
        CompletionWorkProbe.shared.reset()
        let writing = Task { try await enqueue(writer, value) }
        await waitForGate(gate)
        XCTAssertEqual(try Data(contentsOf: writer.fileURL).count, 0)
        let reading = Task { await recover(initial, from: dir) }
        await waitForSubmission("recoveryStarts")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(CompletionWorkProbe.shared.sample()["recoveryFinishes", default: 0], 0)
        gate.release.signal()
        try await writing.value
        let recovered = await reading.value
        XCTAssertTrue(recovered.report.failures.isEmpty)
        XCTAssertEqual(recovered.report.recoveredMessageIDs, [value.id])
        XCTAssertEqual(recovered.snapshot.messagesByConversation[chat]?.last, value)
        writer.closeKeepingFile()
    }
    func testRetiredRunCannotBeRecreatedByLateJournalCompletion() async throws {
        let manager = IOSBackgroundGenerationManager.completionTestManager(), dir = try directory(), chat = UUID()
        let value = message(chat)
        let writer = try PendingGenerationCompletionJournal.makeWriter(runID: value.id, conversationID: chat, directoryURL: dir)
        manager.completionInstallRun(value, writer: writer)
        let gate = CompletionWorkGate(); writer.completionHoldQueue(gate)
        await waitForGate(gate)
        let pending = Task { await manager.stageCompletedMessageWithoutBlockingMain(runID: value.id, message: value) }
        CompletionWorkProbe.shared.reset()
        await waitForSubmission("journalSubmissions")
        gate.release.signal(); manager.cancel(runID: value.id)
        let accepted = await pending.value
        XCTAssertFalse(accepted); XCTAssertNil(manager.completionJournaled(value.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.fileURL.path))
    }

    func testLateUserStopDuringJournalKeepsCompletedReply() async throws {
        let (model, initial, dir) = try fixture(), chat = initial.conversations[0].id
        var reply = message(chat, text: "partial"); reply.status = .streaming
        let writer = try PendingGenerationCompletionJournal.makeWriter(runID: reply.id, conversationID: chat, directoryURL: directory())
        let manager = IOSBackgroundGenerationManager.shared
        manager.completionInstallRun(reply, writer: writer)
        defer { manager.cancel(runID: reply.id) }
        model.completionBegin(reply, raw: "finished before late stop")
        let gate = CompletionWorkGate(); writer.completionHoldQueue(gate)
        await waitForGate(gate)
        CompletionWorkProbe.shared.reset()
        let pending = Task { try await model.completionFinish(chat, messageID: reply.id) }
        await waitForSubmission("journalSubmissions")
        model.stopStreaming()
        XCTAssertEqual(CompletionWorkProbe.shared.sample()["submissions", default: 0], 0)
        model.isDrawerPresented = true
        gate.release.signal()
        let final = try await pending.value
        XCTAssertEqual(final?.status, .complete)
        XCTAssertTrue(model.isDrawerPresented)
        XCTAssertEqual(try load(dir).messagesByConversation[chat]?.last?.text, "finished before late stop")
    }

    func testForcedStopDuringJournalDoesNotSubmitStalePrimarySave() async throws {
        let (model, initial, dir) = try fixture(), chat = initial.conversations[0].id
        var reply = message(chat); reply.status = .streaming
        let writer = try PendingGenerationCompletionJournal.makeWriter(runID: reply.id, conversationID: chat, directoryURL: directory())
        let manager = IOSBackgroundGenerationManager.shared
        manager.completionInstallRun(reply, writer: writer)
        model.completionBegin(reply, raw: "completed then retired")
        let gate = CompletionWorkGate(); writer.completionHoldQueue(gate)
        await waitForGate(gate)
        CompletionWorkProbe.shared.reset()
        let pending = Task { try await model.completionFinish(chat, messageID: reply.id) }
        await waitForSubmission("journalSubmissions")
        gate.release.signal(); model.completionForcedStop(chat)
        do { _ = try await pending.value; XCTFail("Retired completion continued saving") }
        catch is CancellationError {} catch { throw error }
        XCTAssertEqual(CompletionWorkProbe.shared.sample()["submissions", default: 0], 0)
        XCTAssertNil(manager.completionJournaled(reply.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.fileURL.path))
        XCTAssertEqual(try load(dir).messagesByConversation, initial.messagesByConversation)
    }

    func testCancelledPostImageJournalReleasesItsRunAfterActiveIDWasCleared() async throws {
        let (model, initial, _) = try fixture(), chat = initial.conversations[0].id
        let reply = message(chat)
        let writer = try PendingGenerationCompletionJournal.makeWriter(runID: reply.id, conversationID: chat, directoryURL: directory())
        let manager = IOSBackgroundGenerationManager.shared
        manager.completionInstallRun(reply, writer: writer)
        manager.markConversationStoreCommitted(runID: reply.id, message: reply)
        let gate = CompletionWorkGate(); writer.completionHoldQueue(gate)
        await waitForGate(gate)
        CompletionWorkProbe.shared.reset()
        let pending = Task { try await model.completionRestage(reply) }
        await waitForSubmission("journalSubmissions")
        pending.cancel(); gate.release.signal()
        do { try await pending.value; XCTFail("Cancelled restage was accepted") }
        catch is CancellationError {} catch { throw error }
        XCTAssertNil(manager.completionJournaled(reply.id))
        XCTAssertNil(manager.completionCommitted(reply.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.fileURL.path))
    }

    func testJournalFailureStillCommitsPrimaryAndPrimaryFailureRetainsRecoveryJournal() async throws {
        for journalFails in [true, false] {
            let (model, initial, dir) = try fixture(), chat = initial.conversations[0].id
            var reply = message(chat); reply.status = .streaming
            let writer = try PendingGenerationCompletionJournal.makeWriter(runID: reply.id, conversationID: chat, directoryURL: directory())
            let manager = IOSBackgroundGenerationManager.shared
            manager.completionInstallRun(reply, writer: writer)
            if journalFails { writer.closeKeepingFile() } else { model.completionFailCommits(true) }
            model.completionBegin(reply, raw: "recoverable completed reply")
            let finished = try await model.completionFinish(chat, messageID: reply.id)
            let completed = try XCTUnwrap(finished)
            XCTAssertEqual(manager.completionCommitted(reply.id) != nil, journalFails)
            XCTAssertEqual(manager.completionJournaled(reply.id) != nil, !journalFails)
            manager.finish(runID: reply.id, completedMessage: completed, notificationMessage: completed.text)
            XCTAssertEqual(FileManager.default.fileExists(atPath: writer.fileURL.path), !journalFails)
            if journalFails {
                XCTAssertEqual(try load(dir).messagesByConversation[chat]?.last?.text, completed.text)
            } else {
                XCTAssertEqual(try load(dir).messagesByConversation, initial.messagesByConversation)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let record = try decoder.decode(PendingGenerationCompletionRecord.self, from: Data(contentsOf: writer.fileURL))
                XCTAssertEqual(record.message?.text, completed.text)
            }
        }
    }
    func testNormalCompletionJournalsThenCommitsExactFinalTextAndSkipsRepeatWrite() async throws {
        let (model, initial, dir) = try fixture(), chat = initial.conversations[0].id
        var reply = message(chat, text: "partial"); reply.status = .streaming
        let journalDir = try directory()
        let writer = try PendingGenerationCompletionJournal.makeWriter(runID: reply.id, conversationID: chat, directoryURL: journalDir)
        let manager = IOSBackgroundGenerationManager.shared
        manager.completionInstallRun(reply, writer: writer)
        model.completionBegin(reply, raw: "  final 中文 🐈\n\n\nend  ")
        CompletionWorkProbe.shared.reset()
        let finished = try await model.completionFinish(chat, messageID: reply.id)
        let completed = try XCTUnwrap(finished)
        XCTAssertEqual(completed.text, "final 中文 🐈\n\nend")
        XCTAssertEqual(completed.status, .complete)
        XCTAssertEqual(try load(dir).messagesByConversation[chat]?.last?.text, completed.text)
        let stageAgain = await manager.stageCompletedMessageWithoutBlockingMain(runID: reply.id, message: completed)
        XCTAssertTrue(stageAgain)
        XCTAssertEqual(CompletionWorkProbe.shared.sample()["journalWrites"], 1)
        XCTAssertEqual(CompletionWorkProbe.shared.sample()["mainJournalWrites", default: 0], 0)
        XCTAssertEqual(CompletionWorkProbe.shared.sample()["mainIdentityCaptures", default: 0], 0)
        XCTAssertEqual(manager.completionCommitted(reply.id), completed)
        print("COMPLETION_JOURNAL_PROOF " + String(decoding: try JSONSerialization.data(withJSONObject: CompletionWorkProbe.shared.sample(), options: [.sortedKeys]), as: UTF8.self))
        manager.finish(runID: reply.id, completedMessage: completed, notificationMessage: completed.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.fileURL.path))
    }
}
