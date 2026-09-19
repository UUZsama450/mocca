import SwiftUI

struct QuickPhrase: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var content: String
    var isGlobal: Bool
    /// 非全局短语归属的助手 ID（uuidString）。
    var assistantID: String?

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        isGlobal: Bool = true,
        assistantID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.isGlobal = isGlobal
        self.assistantID = assistantID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        isGlobal = try container.decodeIfPresent(Bool.self, forKey: .isGlobal) ?? true
        assistantID = try container.decodeIfPresent(String.self, forKey: .assistantID)
    }
}

enum QuickPhrasePersistence {
    private static let key = "quick_phrases_v1"

    static func load() -> [QuickPhrase] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let phrases = try? JSONDecoder().decode([QuickPhrase].self, from: data) else {
            return []
        }
        return phrases
    }

    static func save(_ phrases: [QuickPhrase]) {
        guard let data = try? JSONEncoder().encode(phrases) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct QuickPhrasePage: View {
    @Environment(AppModel.self) private var model
    @State private var editingPhrase: QuickPhrase?

    var body: some View {
        List {
            if model.quickPhrases.isEmpty {
                ContentUnavailableView(
                    L10n.lookup("还没有快捷短语"),
                    systemImage: "bolt",
                    description: Text(L10n.lookup("常用的话存成短语，输入框旁一键插入"))
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(model.quickPhrases) { phrase in
                        Button {
                            editingPhrase = phrase
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(phrase.title.isEmpty ? L10n.lookup("未命名短语") : phrase.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(phrase.content)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(phrase.isGlobal ? L10n.lookup("全局") : L10n.lookup("当前助手"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(phrase.isGlobal ? Color.accentColor : .secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule().fill(
                                            (phrase.isGlobal ? Color.accentColor : Color.secondary)
                                                .opacity(0.12)
                                        )
                                    )
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for offset in offsets.sorted(by: >)
                        where model.quickPhrases.indices.contains(offset) {
                            model.deleteQuickPhrase(model.quickPhrases[offset].id)
                        }
                    }
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("快捷短语"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingPhrase = QuickPhrase()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.lookup("新建快捷短语"))
            }
        }
        .sheet(item: $editingPhrase) { phrase in
            QuickPhraseEditorView(phrase: phrase) { saved in
                model.upsertQuickPhrase(saved)
            }
        }
    }
}

private struct QuickPhraseEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var phrase: QuickPhrase
    let onSave: (QuickPhrase) -> Void

    init(phrase: QuickPhrase, onSave: @escaping (QuickPhrase) -> Void) {
        _phrase = State(initialValue: phrase)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.lookup("标题")) {
                    TextField(L10n.lookup("短语名称"), text: $phrase.title)
                }
                Section(L10n.lookup("内容")) {
                    NativeMultilineTextEditor(
                        text: $phrase.content,
                        font: .system(size: 16)
                    )
                        .frame(minHeight: 140)
                }
                Section {
                    Toggle(L10n.lookup("全局可用"), isOn: $phrase.isGlobal)
                } footer: {
                    Text(phrase.isGlobal
                        ? L10n.lookup("所有助手都能用这条短语")
                        : L10n.format("只在助手「%@」下显示", [String(describing: model.currentAssistant.name)]))
                }
            }
            .settingsGroupedPageStyle()
            .navigationTitle(phrase.title.isEmpty ? L10n.lookup("快捷短语") : phrase.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消")) { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("保存")) {
                        if !phrase.isGlobal && phrase.assistantID == nil {
                            phrase.assistantID = model.currentAssistantID.uuidString
                        }
                        if phrase.isGlobal {
                            phrase.assistantID = nil
                        }
                        onSave(phrase)
                        dismiss()
                    }
                        .foregroundStyle(.primary)
                    .disabled(phrase.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
