import Foundation

enum AssistantFileToolRequest: Sendable {
    case read(fileID: UUID)
    case edit(fileID: UUID, expectedRevision: Int, content: String)

    var fileID: UUID {
        switch self {
        case .read(let id), .edit(let id, _, _): id
        }
    }
}

/// Files are saved as an assistant subresource. Every mutation begins with the
/// live profile, so neither a tool nor an open editor can replace other settings.
extension AppModel {
    @discardableResult
    func saveAssistantFile(
        assistantID: UUID,
        file: AssistantFile,
        expectedRevision: Int?
    ) throws -> AssistantFile {
        guard let assistant = assistants.first(where: { $0.id == assistantID }) else {
            throw AssistantFileError.missingAssistant
        }
        var files = assistant.files
        let saved: AssistantFile
        if let expectedRevision {
            guard let index = files.firstIndex(where: { $0.id == file.id }) else {
                throw AssistantFileError.missingFile
            }
            saved = try AssistantFileService.update(
                files[index], expectedRevision: expectedRevision,
                fileName: file.fileName, content: file.content,
                isEnabled: file.isEnabled,
                allowsAssistantEditing: file.allowsAssistantEditing,
                largeContentApproved: file.largeContentApproved
            )
            files[index] = saved
        } else {
            guard !files.contains(where: { $0.id == file.id }) else {
                throw AssistantFileError.duplicateID
            }
            saved = AssistantFile(
                id: file.id,
                fileName: try AssistantFileService.normalizedFileName(file.fileName),
                content: file.content,
                isEnabled: file.isEnabled,
                allowsAssistantEditing: file.allowsAssistantEditing,
                largeContentApproved: file.largeContentApproved
            )
            files.append(saved)
        }
        try commitAssistantFiles(files, assistantID: assistantID)
        return saved
    }

    func appendAssistantFiles(assistantID: UUID, files imported: [AssistantFile]) throws {
        guard let assistant = assistants.first(where: { $0.id == assistantID }) else {
            throw AssistantFileError.missingAssistant
        }
        // Imports are one transaction: a rejected batch never leaves half its
        // files behind. Imported text does not confer write access.
        let additions = try imported.map { file in
            AssistantFile(
                id: file.id,
                fileName: try AssistantFileService.normalizedFileName(file.fileName),
                content: file.content,
                isEnabled: true,
                allowsAssistantEditing: false,
                largeContentApproved: file.largeContentApproved
            )
        }
        try commitAssistantFiles(assistant.files + additions, assistantID: assistantID)
    }

    func removeAssistantFile(
        assistantID: UUID, fileID: UUID, expectedRevision: Int
    ) throws {
        guard let assistant = assistants.first(where: { $0.id == assistantID }) else {
            throw AssistantFileError.missingAssistant
        }
        guard let file = assistant.files.first(where: { $0.id == fileID }) else {
            throw AssistantFileError.missingFile
        }
        guard file.revision == expectedRevision else {
            throw AssistantFileError.revisionConflict
        }
        try commitAssistantFiles(
            assistant.files.filter { $0.id != fileID }, assistantID: assistantID
        )
    }

    @discardableResult
    func undoAssistantFile(
        assistantID: UUID, fileID: UUID, expectedRevision: Int
    ) throws -> AssistantFile {
        guard let assistant = assistants.first(where: { $0.id == assistantID }) else {
            throw AssistantFileError.missingAssistant
        }
        var files = assistant.files
        guard let index = files.firstIndex(where: { $0.id == fileID }) else {
            throw AssistantFileError.missingFile
        }
        let restored = try AssistantFileService.undo(files[index], expectedRevision: expectedRevision)
        files[index] = restored
        try commitAssistantFiles(files, assistantID: assistantID)
        return restored
    }

    private func commitAssistantFiles(_ files: [AssistantFile], assistantID: UUID) throws {
        try AssistantFileService.validate(files)
        guard let index = assistants.firstIndex(where: { $0.id == assistantID }) else {
            throw AssistantFileError.missingAssistant
        }
        var candidate = assistants
        candidate[index].files = files
        guard AssistantPersistence.saveAssistants(candidate) else {
            throw AssistantFileError.persistenceFailed
        }
        assistants = candidate
    }

    func executeAssistantFileToolWithConfirmation(
        _ request: AssistantFileToolRequest,
        assistantID: UUID,
        readableFileIDs: Set<UUID>,
        writableFileIDs: Set<UUID>,
        isCurrent: @MainActor () -> Bool
    ) async -> String {
        guard !Task.isCancelled, isCurrent() else {
            return Self.assistantFileToolError("request_expired", "本轮回复已结束，文件未修改。")
        }
        var approved = false
        if case .edit(_, let revision, let content) = request,
           largeFileConfirmation.isEnabled,
           readableFileIDs.contains(request.fileID), writableFileIDs.contains(request.fileID),
           let file = assistants.first(where: { $0.id == assistantID })?.files.first(where: { $0.id == request.fileID }),
           file.isEnabled, file.allowsAssistantEditing, file.revision == revision,
           file.largeContentApproved != true {
            let oversized = await Task.detached(priority: .userInitiated) {
                LargeFilePolicy.needsConfirmation(content)
            }.value
            if oversized {
                guard await largeFileConfirmation.confirm(names: [file.fileName], assistantFile: true, includesLargeFile: LargeFilePolicy.exceedsByteLimit(Int64(content.utf8.count))) else {
                    return Self.assistantFileToolError("user_cancelled", "用户取消了超大文件修改，原文件保持不变。")
                }
                approved = true
            }
        }
        guard !Task.isCancelled, isCurrent() else {
            return Self.assistantFileToolError("request_expired", "本轮回复已结束，文件未修改。")
        }
        return executeAssistantFileTool(request, assistantID: assistantID,
            readableFileIDs: readableFileIDs, writableFileIDs: writableFileIDs,
            largeContentApproved: approved)
    }

    /// The calling stream checks its run/message identity immediately before
    /// entering this synchronous MainActor transaction. Permissions are checked
    /// both against that request's grant and against the live file below.
    func executeAssistantFileTool(
        _ request: AssistantFileToolRequest,
        assistantID: UUID,
        readableFileIDs: Set<UUID>,
        writableFileIDs: Set<UUID>,
        largeContentApproved: Bool = false
    ) -> String {
        guard readableFileIDs.contains(request.fileID),
              let assistant = assistants.first(where: { $0.id == assistantID }),
              let index = assistant.files.firstIndex(where: { $0.id == request.fileID }),
              assistant.files[index].isEnabled else {
            return Self.assistantFileToolError("file_unavailable", "文件不存在或已停用。")
        }
        var files = assistant.files
        do {
            var result: AssistantFile
            switch request {
            case .read:
                result = files[index]
            case .edit(_, let expectedRevision, let content):
                guard writableFileIDs.contains(request.fileID) else {
                    return Self.assistantFileToolError("edit_not_allowed", "本轮未获准修改这个文件。")
                }
                result = try AssistantFileService.updateByAssistant(
                    files[index], expectedRevision: expectedRevision, content: content
                )
                if largeContentApproved { result.largeContentApproved = true }
                files[index] = result
                try commitAssistantFiles(files, assistantID: assistantID)
            }
            return Self.assistantFileToolJSON([
                "ok": true,
                "file": [
                    "id": result.id.uuidString,
                    "file_name": result.fileName,
                    "content": result.content,
                    "revision": result.revision,
                    "allows_assistant_editing": result.allowsAssistantEditing
                ]
            ])
        } catch {
            return Self.assistantFileToolError("file_update_failed", error.localizedDescription)
        }
    }

    static func assistantFileToolError(_ code: String, _ message: String) -> String {
        assistantFileToolJSON(["ok": false, "error": code, "message": message])
    }

    private static func assistantFileToolJSON(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"encoding_failed\"}"
        }
        return text
    }
}
