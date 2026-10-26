import SwiftUI

/// Observation is confined to this small label; progress changes once per page.
struct DocumentReadingProgressLabel: View {
    @Environment(AppModel.self) private var model
    let messageID: UUID
    var body: some View {
        if let progress = model.documentReadingProgress[messageID] {
            Text(progress).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).frame(maxWidth: 230, alignment: .leading)
        }
    }
}

struct DocumentAttachmentButton<Label: View>: View {
    @Environment(AppModel.self) private var model
    let attachment: MessageAttachment
    var messageID: UUID? = nil
    @ViewBuilder let label: () -> Label
    @State private var presented = false
    @State private var conversationID: UUID?
    var body: some View {
        Button {
            conversationID = model.selectedConversationID
            presented = true
        } label: { label() }
        .buttonStyle(.plain)
        .accessibilityHint(L10n.lookup("设置文档读取范围"))
        .accessibilityValue(model.documentReadingReports[attachment.id] ?? "")
        .sheet(isPresented: $presented) {
            DocumentAttachmentOptionsView(attachment: attachment, report: model.documentReadingReports[attachment.id]) { options in
                model.updateDocumentOptions(options, attachmentID: attachment.id,
                    messageID: messageID, conversationID: conversationID)
            }
        }
    }
}

private struct DocumentAttachmentOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: MessageAttachment
    let report: String?
    let save: (DocumentOptions) -> Bool
    @State private var options: DocumentOptions
    @State private var totalPages: Int?
    @State private var error: String?

    init(attachment: MessageAttachment, report: String?, save: @escaping (DocumentOptions) -> Bool) {
        self.attachment = attachment; self.report = report; self.save = save
        _options = State(initialValue: DocumentOptions(metadata: attachment.metadata))
    }
    private var isPDF: Bool { DocumentAttachmentReader.format(attachment) == "pdf" }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(attachment.fileName ?? L10n.lookup("文件"))
                    Toggle(L10n.lookup("仅提取文字"), isOn: $options.textOnly)
                    Text(L10n.lookup("开启 OCR 时，页面与图片由所选 OCR 模型识别；关闭时交给支持图片的聊天模型。纯文本模型只读取正文。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isPDF {
                    Section(L10n.lookup("PDF 页码范围")) {
                        TextField(L10n.lookup("全部页，或填写 1-5,8"), text: $options.pages)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if let totalPages { Text(L10n.format("共 %@ 页", [String(totalPages)])) }
                        Text(L10n.lookup("默认读取全部页面。可按需选择页码范围或仅提取文字，以减少处理时间和模型用量。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let report {
                    Section(L10n.lookup("本次运行中的最近读取")) { Text(report).font(.caption) }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.caption) } }
                Section {
                    Text(L10n.lookup("保存设置不会自动发送。读取失败后可在消息菜单中重新生成，已成功的 OCR 结果会在本次运行中复用。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.lookup("文档读取"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.lookup("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("保存")) {
                        do {
                            if isPDF, let totalPages { _ = try options.indices(total: totalPages) }
                            options.pages = options.pages.trimmingCharacters(in: .whitespacesAndNewlines)
                            if save(options) { dismiss() }
                            else { error = L10n.lookup("当前无法修改附件，请停止生成后重试。") }
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .task {
                if isPDF {
                    do { totalPages = try await DocumentAttachmentReader.shared.pageCount(attachment) }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }
}
