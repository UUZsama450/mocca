import SwiftUI
import UniformTypeIdentifiers

private enum AssistantMarkdownDocumentType {
    static let markdown = UTType(filenameExtension: "md") ?? .plainText
    static let importTypes: [UTType] = [
        markdown,
        UTType(filenameExtension: "markdown") ?? .plainText,
        .plainText,
    ]
}

private struct AssistantMarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { AssistantMarkdownDocumentType.importTypes }
    static var writableContentTypes: [UTType] { [AssistantMarkdownDocumentType.markdown] }

    let content: String

    init(content: String) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let decoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        content = decoded
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(content.utf8))
    }
}

struct AssistantFilesSettingsView: View {
    @Environment(AppModel.self) private var model

    let assistantID: UUID

    @State private var editorSelection: AssistantFileEditorSelection?
    @State private var importPresented = false
    @State private var importTask: Task<Void, Never>?
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var exportDocument: AssistantMarkdownDocument?
    @State private var exportFileName = L10n.lookup("未命名.md")
    @State private var exportPresented = false
    @State private var fileToDelete: AssistantFile?

    // Files are saved separately from the surrounding assistant settings draft.
    private var files: [AssistantFile] {
        model.assistants.first(where: { $0.id == assistantID })?.files ?? []
    }

    var body: some View {
        List {
            Section {
                if isImporting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.lookup("正在导入 Markdown 文件…"))
                            .foregroundStyle(.secondary)
                    }
                }

                if files.isEmpty {
                    ContentUnavailableView(
                        L10n.lookup("还没有文件"),
                        systemImage: "doc.text",
                        description: Text(L10n.lookup("添加 Markdown 文件，为这个助手提供规则或参考资料。"))
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(files) { file in
                        Button {
                            editorSelection = AssistantFileEditorSelection(file: file, isNew: false)
                        } label: {
                            fileRow(file)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(L10n.lookup("编辑"), systemImage: "pencil") {
                                editorSelection = AssistantFileEditorSelection(file: file, isNew: false)
                            }
                            Button(L10n.lookup("导出 Markdown"), systemImage: "square.and.arrow.up") {
                                export(file)
                            }
                            Button(L10n.lookup("删除"), systemImage: "trash", role: .destructive) {
                                fileToDelete = file
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text(L10n.lookup("Markdown 文件"))
                    Spacer()
                    Menu {
                        Button(L10n.lookup("导入文件"), systemImage: "square.and.arrow.down") {
                            importPresented = true
                        }
                        Button(L10n.lookup("新建 Markdown"), systemImage: "doc.badge.plus") {
                            editorSelection = AssistantFileEditorSelection(file: AssistantFile(), isNew: true)
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 36)
                            .contentShape(Rectangle())
                    }
                    .tint(Color(uiColor: .systemBlue))
                    .accessibilityLabel(L10n.lookup("添加助手文件"))
                    .disabled(isImporting || files.count >= AssistantFileService.maximumFileCount)
                }
                .textCase(nil)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.lookup("启用的文件会用于这个助手的每次聊天，内容会发送给你选择的模型服务。文件在这里独立保存，无需再保存外层助手设置。"))
                    Text(L10n.lookup("支持 Markdown 文件（.md、.markdown）；每份最多 64 KB，每个助手最多 32 份，合计 256 KB。"))
                    if !files.isEmpty {
                        Text(L10n.format("已使用 %@ / 32 份 · %@", [String(describing: files.count), String(describing: ByteCountFormatter.string(fromByteCount: Int64(files.reduce(0) { $0 + $1.byteCount }), countStyle: .file))]))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(item: $editorSelection) { selection in
            AssistantFileEditorView(
                assistantID: assistantID,
                file: selection.file,
                isNew: selection.isNew
            )
        }
        .fileImporter(
            isPresented: $importPresented,
            allowedContentTypes: AssistantMarkdownDocumentType.importTypes,
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
        .fileExporter(
            isPresented: $exportPresented,
            document: exportDocument,
            contentType: AssistantMarkdownDocumentType.markdown,
            defaultFilename: exportFileName
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
        }
        .alert(L10n.lookup("文件操作失败"), isPresented: errorPresented) {
            Button(L10n.lookup("好"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? L10n.lookup("请稍后重试。"))
        }
        .alert(L10n.lookup("删除文件？"), isPresented: deletePresented) {
            Button(L10n.lookup("取消"), role: .cancel) { fileToDelete = nil }
            Button(L10n.lookup("删除"), role: .destructive) { deleteSelectedFile() }
        } message: {
            Text(L10n.format("将从这个助手中删除“%@”。已发送的聊天内容不会改变。", [String(describing: fileToDelete?.fileName ?? "")]))
        }
        .onDisappear {
            importTask?.cancel()
            importTask = nil
            isImporting = false
        }
    }

    private func fileRow(_ file: AssistantFile) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 22))
                .foregroundStyle(file.isEnabled ? Color(uiColor: model.themeAccentUIColor) : .secondary)
                .frame(width: 28)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(file.fileName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(preview(file.content))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Label(file.isEnabled ? L10n.lookup("使用中") : L10n.lookup("已停用"), systemImage: file.isEnabled ? "checkmark.circle" : "pause.circle")
                    Label(file.allowsAssistantEditing ? L10n.lookup("助手可编辑") : L10n.lookup("只读"), systemImage: file.allowsAssistantEditing ? "pencil" : "lock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 5)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func preview(_ content: String) -> String {
        let prefix = String(content.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? L10n.lookup("空白文件") : prefix
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else { return }
            guard urls.count <= AssistantFileService.maximumFileCount - files.count else {
                errorMessage = L10n.lookup("每个助手最多保存 32 份文件，请减少这次选择的文件数量。")
                return
            }
            isImporting = true
            importTask = Task { @MainActor in
                defer {
                    isImporting = false
                    importTask = nil
                }
                do {
                    var imported: [AssistantFile] = []
                    for url in urls {
                        try Task.checkCancellation()
                        imported.append(try await AssistantFileService.prepareImport(from: url))
                    }
                    try Task.checkCancellation()
                    try model.appendAssistantFiles(assistantID: assistantID, files: imported)
                } catch is CancellationError {
                    // Leaving the page cancels an unfinished import before it is saved.
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func export(_ file: AssistantFile) {
        exportFileName = file.fileName
        exportDocument = AssistantMarkdownDocument(content: file.content)
        exportPresented = true
    }

    private func deleteSelectedFile() {
        guard let file = fileToDelete else { return }
        fileToDelete = nil
        do {
            try model.removeAssistantFile(
                assistantID: assistantID,
                fileID: file.id,
                expectedRevision: file.revision
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { fileToDelete != nil }, set: { if !$0 { fileToDelete = nil } })
    }
}

private struct AssistantFileEditorSelection: Identifiable {
    let file: AssistantFile
    let isNew: Bool
    var id: UUID { file.id }
}

private struct AssistantFileEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let assistantID: UUID
    private let originalFile: AssistantFile
    private let expectedRevision: Int?

    @State private var draft: AssistantFile
    @State private var errorMessage: String?
    @State private var unsavedChangesPresented = false
    @State private var deletePresented = false
    @State private var undoPresented = false
    @State private var exportPresented = false
    @State private var exportDocument: AssistantMarkdownDocument?
    @FocusState private var nameIsFocused: Bool

    init(assistantID: UUID, file: AssistantFile, isNew: Bool) {
        self.assistantID = assistantID
        originalFile = file
        expectedRevision = isNew ? nil : file.revision
        _draft = State(initialValue: file)
    }

    private var liveFile: AssistantFile? {
        model.assistants.first(where: { $0.id == assistantID })?.files.first(where: { $0.id == originalFile.id })
    }

    private var hasConflict: Bool {
        guard let expectedRevision else { return false }
        return liveFile?.revision != expectedRevision
    }

    private var hasUnsavedChanges: Bool {
        draft.fileName != originalFile.fileName
            || draft.content != originalFile.content
            || draft.isEnabled != originalFile.isEnabled
            || draft.allowsAssistantEditing != originalFile.allowsAssistantEditing
    }

    private var canSave: Bool {
        !draft.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.byteCount <= AssistantFileService.maximumFileBytes
            && !hasConflict
    }

    var body: some View {
        NavigationStack {
            Form {
                if hasConflict {
                    Section {
                        Label(L10n.lookup("这份文件已被修改或删除。当前输入仍在，请复制需要保留的内容，再关闭并重新打开文件。"), systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                Section(L10n.lookup("文件名")) {
                    TextField(L10n.lookup("未命名.md"), text: $draft.fileName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($nameIsFocused)
                }

                Section {
                    Toggle(L10n.lookup("聊天时使用"), isOn: $draft.isEnabled)
                    Toggle(L10n.lookup("允许助手编辑"), isOn: $draft.allowsAssistantEditing)
                } footer: {
                    Text(L10n.lookup("启用后，每次聊天都会将文件内容发送给所选模型服务。允许编辑后，助手可以自动保存正文修改；文件名与权限仍由你设置。可恢复一次上版正文。"))
                }

                Section {
                    NativeMultilineTextEditor(
                        text: $draft.content,
                        font: .monospacedBody,
                        autocapitalizationType: .none,
                        autocorrectionType: .no
                    )
                    .frame(minHeight: 320)
                    .padding(.vertical, 4)
                } header: {
                    Text(L10n.lookup("Markdown 正文"))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.format("%@ / 65,536 字节", [String(describing: draft.byteCount)]))
                            .foregroundStyle(draft.byteCount > AssistantFileService.maximumFileBytes ? Color.red : .secondary)
                        if draft.byteCount > AssistantFileService.maximumFileBytes {
                            Text(L10n.lookup("文件超过 64 KB，请缩短内容后保存。输入不会被自动截断。"))
                                .foregroundStyle(.red)
                        }
                        Text(L10n.lookup("点按“保存”后立即生效。这里只保存文本，不会执行文件中的脚本。"))
                    }
                }

                if expectedRevision != nil {
                    Section(L10n.lookup("已保存版本")) {
                        LabeledContent(L10n.lookup("版本"), value: "\(originalFile.revision)")
                        LabeledContent(L10n.lookup("修改者"), value: originalFile.lastModifiedBy == .assistant ? L10n.lookup("助手") : L10n.lookup("你"))
                        LabeledContent(L10n.lookup("修改时间")) {
                            Text(originalFile.updatedAt, format: .dateTime.year().month().day().hour().minute())
                        }
                    }
                }
            }
            .navigationTitle(expectedRevision == nil ? L10n.lookup("新建文件") : L10n.lookup("编辑文件"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消"), action: requestDismissal)
                        .foregroundStyle(.primary)
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    fileMenu
                    Button(L10n.lookup("保存"), action: saveAndDismiss)
                        .foregroundStyle(.primary)
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .interactiveDismissDisabled(hasUnsavedChanges)
        .fileExporter(
            isPresented: $exportPresented,
            document: exportDocument,
            contentType: AssistantMarkdownDocumentType.markdown,
            defaultFilename: draft.fileName
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .alert(L10n.lookup("文件尚未保存"), isPresented: $unsavedChangesPresented) {
            if canSave { Button(L10n.lookup("保存"), action: saveAndDismiss) }
            Button(L10n.lookup("不保留修改"), role: .destructive) { dismiss() }
            Button(L10n.lookup("继续编辑"), role: .cancel) {}
        } message: {
            Text(L10n.lookup("关闭后，尚未保存的文件修改会丢失。"))
        }
        .alert(L10n.lookup("删除文件？"), isPresented: $deletePresented) {
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(L10n.lookup("删除"), role: .destructive, action: deleteAndDismiss)
        } message: {
            Text(L10n.format("将从这个助手中删除“%@”。已发送的聊天内容不会改变。", [String(describing: originalFile.fileName)]))
        }
        .alert(L10n.lookup("恢复上版文件？"), isPresented: $undoPresented) {
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(L10n.lookup("恢复上版"), action: undoAndDismiss)
        } message: {
            Text(L10n.lookup("恢复上次保存前的文件名与正文；当前的使用和编辑权限会保留。恢复后不能再次撤销。"))
        }
        .alert(L10n.lookup("文件操作失败"), isPresented: errorPresented) {
            Button(L10n.lookup("好"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? L10n.lookup("请稍后重试。"))
        }
    }

    private var fileMenu: some View {
        Menu {
            Button(L10n.lookup("重命名"), systemImage: "pencil") { nameIsFocused = true }
            Button(L10n.lookup("导出 Markdown"), systemImage: "square.and.arrow.up") {
                exportDocument = AssistantMarkdownDocument(content: draft.content)
                exportPresented = true
            }
            if expectedRevision != nil {
                Button(L10n.lookup("恢复上版文件"), systemImage: "arrow.uturn.backward") { undoPresented = true }
                    .disabled(originalFile.previousVersion == nil || hasUnsavedChanges || hasConflict)
                Button(L10n.lookup("删除文件"), systemImage: "trash", role: .destructive) { deletePresented = true }
                    .disabled(hasUnsavedChanges || hasConflict)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L10n.lookup("文件操作"))
    }

    private func requestDismissal() {
        if hasUnsavedChanges { unsavedChangesPresented = true } else { dismiss() }
    }

    private func saveAndDismiss() {
        do {
            _ = try model.saveAssistantFile(
                assistantID: assistantID,
                file: draft,
                expectedRevision: expectedRevision
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteAndDismiss() {
        guard let expectedRevision else { return }
        do {
            try model.removeAssistantFile(
                assistantID: assistantID,
                fileID: originalFile.id,
                expectedRevision: expectedRevision
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func undoAndDismiss() {
        guard let expectedRevision else { return }
        do {
            _ = try model.undoAssistantFile(
                assistantID: assistantID,
                fileID: originalFile.id,
                expectedRevision: expectedRevision
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}
