import XCTest
@testable import Mocca

@MainActor final class ReviewCorrectnessTests: XCTestCase {
    private func fixture() throws -> (AppModel, ConversationSnapshot) {
        let m = AppModel()
        let a = Conversation(title: "A", createdAt: Date(timeIntervalSince1970: 200), updatedAt: Date(timeIntervalSince1970: 200), assistantID: m.currentAssistantID.uuidString)
        let b = Conversation(title: "B", createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100), assistantID: m.currentAssistantID.uuidString)
        var reply = ChatMessage(conversationID: a.id, role: .assistant, text: "selected answer", createdAt: Date(timeIntervalSince1970: 300), updatedAt: Date(timeIntervalSince1970: 300), versionGroupID: "versions", version: 2)
        reply.reactions.bookmarkedAt = Date(timeIntervalSince1970: 300)
        let old = ChatMessage(conversationID: a.id, role: .assistant, text: "old answer", createdAt: Date(timeIntervalSince1970: 300), updatedAt: Date(timeIntervalSince1970: 300), versionGroupID: "versions", version: 1)
        let value = ConversationSnapshot(conversations: [a,b], messagesByConversation: [a.id:[old,reply],b.id:[]])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try m.reviewInstallStore(value, directory: dir)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (m,value)
    }

    func testA3FailedSendReloadPreservesExactInputAndAttachmentThenRetry() async throws {
        let (m, initial) = try fixture(), id = initial.conversations[0].id
        let attachment = try await AttachmentStore.savePastedText("synthetic attachment bytes")
        let orphan = try await AttachmentStore.savePastedText("unreferenced synthetic bytes")
        let bytes = try Data(contentsOf: attachment.localURL!)
        m.setComposerDraftText("  unsent 🐈\ntext  ", for: id)
        m.setComposerPendingAttachments([attachment], for: id)
        m.reviewFailCommits(true)
        XCTAssertFalse(m.sendDraft(for: id))
        XCTAssertFalse(m.reviewReady)
        XCTAssertEqual(m.messagesByConversation, initial.messagesByConversation)
        XCTAssertEqual(m.composerDraftText(for:id), "  unsent 🐈\ntext  ")
        m.reviewFailCommits(false)
        m.retryConversationStoreLoadIfNeeded()
        XCTAssertTrue(m.reviewReady)
        XCTAssertEqual(m.selectedConversationID, id)
        XCTAssertEqual(m.messagesByConversation, initial.messagesByConversation)
        XCTAssertEqual(m.composerDraftText(for:id), "  unsent 🐈\ntext  ")
        XCTAssertEqual(m.composerPendingAttachments(for:id), [attachment])
        XCTAssertEqual(try Data(contentsOf: attachment.localURL!), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:orphan.localURL!.path))
        // Real send commit succeeds. Stop synchronously before its provider task runs.
        XCTAssertTrue(m.sendDraft(for:id))
        m.stopStreaming()
        XCTAssertTrue(m.composerDraftText(for:id).isEmpty)
        let users = try m.reviewReadStore().messagesByConversation[id]!.filter { $0.role == .user }
        XCTAssertEqual(users.count,1)
        XCTAssertEqual(users[0].attachments,[attachment])
        XCTAssertEqual(users[0].text,"unsent 🐈\ntext")
    }

    func testA3MissingDestinationCreatesEmptyRecoveryChatAndKeepsOtherDraft() async throws {
        let (m, initial) = try fixture(), existing = initial.conversations[0].id
        let lost = Conversation(title:"not on disk",assistantID:m.currentAssistantID.uuidString)
        m.conversations.append(lost);m.messagesByConversation[lost.id]=[];m.reviewMarkUnsaved(lost.id)
        m.selectedConversationID=lost.id
        let file = try await AttachmentStore.savePastedText("recovered file")
        m.setComposerDraftText("orphan input",for:lost.id);m.setComposerPendingAttachments([file],for:lost.id)
        m.setComposerDraftText("other input",for:existing)
        m.reviewFailCommits(true);XCTAssertFalse(m.reviewSave());m.reviewFailCommits(false)
        // The original send ID cannot silently send into a new destination.
        XCTAssertFalse(m.sendDraft(for:lost.id))
        XCTAssertTrue(m.reviewReady)
        let recovered=m.selectedConversationID
        XCTAssertNotEqual(recovered,lost.id)
        XCTAssertEqual(m.selectedConversation?.title,"恢复的未发送草稿")
        XCTAssertEqual(m.messagesByConversation[recovered],[])
        XCTAssertEqual(m.composerDraftText(for:recovered),"orphan input")
        XCTAssertEqual(m.composerPendingAttachments(for:recovered),[file])
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.localURL!.path))
        XCTAssertEqual(m.composerDraftText(for:existing),"other input")
        XCTAssertEqual(try m.reviewReadStore().messagesByConversation,initial.messagesByConversation)
    }

    func testA3ChangedOwnerDoesNotReceiveOldInputAndRepeatedRecoveryDoesNotDuplicate() throws {
        let (m,initial)=try fixture(),id=initial.conversations[0].id
        m.conversations[0].assistantID=UUID().uuidString
        m.setComposerDraftText("old owner draft",for:id)
        m.reviewFailCommits(true);XCTAssertFalse(m.reviewSave());m.reviewFailCommits(false)
        m.retryConversationStoreLoadIfNeeded()
        XCTAssertTrue(m.composerDraftText(for:id).isEmpty)
        XCTAssertEqual(m.draft,"old owner draft")
        XCTAssertNotEqual(m.selectedConversationID,id)
        m.reviewFailCommits(true);XCTAssertFalse(m.reviewSave());m.reviewFailCommits(false)
        m.retryConversationStoreLoadIfNeeded()
        XCTAssertEqual(m.conversations.count,initial.conversations.count+1)
        XCTAssertEqual(m.draft,"old owner draft")
        XCTAssertEqual(m.messagesByConversation[id],initial.messagesByConversation[id])
    }

    func testA4BranchFailureDoesNotNavigateAndRetryCreatesOneSelectedVersionBranch() throws {
        let (m,initial)=try fixture(),id=initial.conversations[0].id
        let target=initial.messagesByConversation[id]!.last!
        m.isDrawerPresented=true;m.isBottomToolsPresented=true
        let bottom=m.conversationBottomReturnRequest
        m.reviewFailCommits(true)
        m.branchConversation(at:target.id)
        XCTAssertEqual(m.conversations,initial.conversations)
        XCTAssertEqual(m.messagesByConversation,initial.messagesByConversation)
        XCTAssertEqual(m.selectedConversationID,id)
        XCTAssertEqual(m.conversationBottomReturnRequest,bottom)
        XCTAssertTrue(m.isDrawerPresented);XCTAssertTrue(m.isBottomToolsPresented)
        XCTAssertEqual(try m.reviewReadStore().messagesByConversation,initial.messagesByConversation)
        m.reviewFailCommits(false);m.retryConversationStoreLoadIfNeeded()
        m.branchConversation(at:target.id)
        XCTAssertEqual(m.conversations.count,initial.conversations.count+1)
        XCTAssertNotEqual(m.selectedConversationID,id)
        XCTAssertEqual(m.messages.count,1);XCTAssertEqual(m.messages[0].text,"selected answer")
        XCTAssertNil(m.messages[0].reactions.bookmarkedAt)
        XCTAssertEqual(m.messagesByConversation[id],initial.messagesByConversation[id])
        XCTAssertEqual(try m.reviewReadStore().conversations.count,initial.conversations.count+1)
    }

    func testA2StopResumesApprovalAndLateAllowCannotMutateCalendar() async throws {
        let (m,initial)=try fixture(),id=initial.conversations[0].id
        let context=m.reviewContext(id)
        let task=Task { await m.requestToolApproval(kind:.calendar,toolName:"delete",preview:"synthetic",context:context) }
        for _ in 0..<1000 { if m.pendingToolApproval != nil { break };await Task.yield() }
        let request=try XCTUnwrap(m.pendingToolApproval)
        m.reviewStop(id)
        let result=await task.value
        XCTAssertEqual(result,.expired);XCTAssertNil(m.pendingToolApproval)
        m.resolveToolApproval(id:request.id,decision:.approved)
        XCTAssertFalse(m.isToolInvocationCurrent(context))
    }
    func testA2CalendarExecutorRechecksCancellationAfterAllow() async throws {
        let (m,initial)=try fixture(),id=initial.conversations[0].id
        let context=m.reviewContext(id)
        m.calendarSettings.assistantAccessEnabled=true
        let event=MoccaCalendarEvent(title:"keep me",startAt:.now)
        m.calendarEvents=[event]
        let t=Task { await m.executeMoccaCalendarTool(name:MoccaCalendarAssistantBridge.deleteTool,
            args:["id":.string(event.id.uuidString)],context:context) }
        for _ in 0..<1000 { if m.pendingToolApproval != nil { break };await Task.yield() }
        let request=try XCTUnwrap(m.pendingToolApproval)
        t.cancel()
        m.resolveToolApproval(id:request.id,decision:.approved)
        let response=await t.value
        XCTAssertTrue(response?.contains("request_expired") == true)
        XCTAssertEqual(m.calendarEvents,[event])
        m.reviewStop(id)
    }

    func testA2CalendarEditsDuringApprovalRequireNewApproval() async throws {
        let (m,initial)=try fixture(),id=initial.conversations[0].id
        let context=m.reviewContext(id)
        m.calendarSettings.assistantAccessEnabled=true
        let event=MoccaCalendarEvent(title:"original",startAt:.now)
        m.calendarEvents=[event]
        let t=Task { await m.executeMoccaCalendarTool(name:MoccaCalendarAssistantBridge.updateTool,
            args:["id":.string(event.id.uuidString),"title":.string("assistant replacement")],context:context) }
        for _ in 0..<1000 { if m.pendingToolApproval != nil { break };await Task.yield() }
        let request=try XCTUnwrap(m.pendingToolApproval)
        m.calendarEvents[0].title="newer user edit"
        m.resolveToolApproval(id:request.id,decision:.approved)
        let response=await t.value
        XCTAssertTrue(response?.contains("request_expired") == true)
        XCTAssertEqual(m.calendarEvents[0].title,"newer user edit")
        m.reviewStop(id)
    }

    func testA2MCPExecutorRechecksCancellationAfterAllow() async throws {
        let (m,initial)=try fixture(),id=initial.conversations[0].id
        let context=m.reviewContext(id)
        let server=MCPServerConfig(name:"synthetic",url:"http://127.0.0.1:1",tools:[MCPToolConfig(name:"write",needsApproval:true)])
        m.mcpServers=[server]
        let index=try XCTUnwrap(m.assistants.firstIndex { $0.id == m.currentAssistantID })
        m.assistants[index].mcpServerIDs=[server.id]
        let assistant=m.assistants[index]
        let t=Task { await m.executeMCPTool(name:"write",args:[:],assistant:assistant,context:context) }
        for _ in 0..<1000 { if m.pendingToolApproval != nil { break };await Task.yield() }
        let request=try XCTUnwrap(m.pendingToolApproval)
        t.cancel();m.resolveToolApproval(id:request.id,decision:.approved)
        let response=await t.value
        XCTAssertTrue(response?.contains("request_expired") == true)
        m.reviewStop(id)
    }

    func testA2A3RecoveryInvalidatesWaitingRunAndKeepsUnsentInput() async throws {
        let (m,initial)=try fixture(),id=initial.conversations[0].id
        let context=m.reviewContext(id)
        m.messagesByConversation[id]![2].text="persisted partial reply"
        XCTAssertTrue(m.reviewSave())
        let t=Task { await m.requestToolApproval(kind:.mcp,toolName:"pending",preview:"synthetic",context:context) }
        for _ in 0..<1000 { if m.pendingToolApproval != nil { break };await Task.yield() }
        XCTAssertNotNil(m.pendingToolApproval)
        m.setComposerDraftText("next unsent input",for:id)
        m.reviewFailCommits(true);XCTAssertFalse(m.reviewSave());m.reviewFailCommits(false)
        m.retryConversationStoreLoadIfNeeded()
        let result=await t.value
        XCTAssertEqual(result,.expired)
        XCTAssertNil(m.pendingToolApproval)
        XCTAssertFalse(m.isToolInvocationCurrent(context))
        XCTAssertEqual(m.composerDraftText(for:id),"next unsent input")
        XCTAssertEqual(m.messagesByConversation[id]!.last?.status,.interrupted)
        XCTAssertEqual(m.messagesByConversation[id]!.last?.text,"persisted partial reply")
        XCTAssertTrue(m.reviewReady)
    }

}
