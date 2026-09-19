import SwiftUI

struct InstructionInjectionPage: View {
    @Environment(AppModel.self) private var model
    @State private var editingInstruction: InstructionInjection?

    var body: some View {
        List {
            if model.instructionInjections.isEmpty {
                ContentUnavailableView(
                    L10n.lookup("还没有指令"),
                    systemImage: "square.stack.3d.up",
                    description: Text(L10n.lookup("新建的指令可以按助手开关，开启后会追加到系统提示词"))
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(model.instructionInjections) { injection in
                        HStack(spacing: 12) {
                            Button {
                                editingInstruction = injection
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(injection.title.isEmpty ? L10n.lookup("未命名指令") : injection.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(injection.prompt)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Toggle(
                                L10n.lookup("启用"),
                                isOn: Binding(
                                    get: { model.isInstructionActive(injection.id) },
                                    set: { _ in model.toggleInstructionActive(injection.id) }
                                )
                            )
                            .labelsHidden()
                        }
                    }
                    .onDelete { offsets in
                        for offset in offsets.sorted(by: >)
                        where model.instructionInjections.indices.contains(offset) {
                            model.deleteInstruction(model.instructionInjections[offset].id)
                        }
                    }
                } footer: {
                    Text(L10n.format("开关只对当前助手「%@」生效", [String(describing: model.currentAssistant.name)]))
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("指令注入"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingInstruction = InstructionInjection()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.lookup("新建指令"))
            }
        }
        .sheet(item: $editingInstruction) { injection in
            InstructionEditorView(injection: injection) { saved in
                model.upsertInstruction(saved)
            }
        }
    }
}

private struct InstructionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var injection: InstructionInjection
    let onSave: (InstructionInjection) -> Void

    init(injection: InstructionInjection, onSave: @escaping (InstructionInjection) -> Void) {
        _injection = State(initialValue: injection)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.lookup("标题")) {
                    TextField(L10n.lookup("指令名称"), text: $injection.title)
                }
                Section(L10n.lookup("提示词")) {
                    NativeMultilineTextEditor(
                        text: $injection.prompt,
                        font: .system(size: 16)
                    )
                        .frame(minHeight: 180)
                }
            }
            .settingsGroupedPageStyle()
            .navigationTitle(injection.title.isEmpty ? L10n.lookup("指令") : injection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消")) { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("保存")) {
                        onSave(injection)
                        dismiss()
                    }
                        .foregroundStyle(.primary)
                    .disabled(injection.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct WorldBookPage: View {
    @Environment(AppModel.self) private var model
    @State private var editingBook: WorldBook?

    var body: some View {
        List {
            if model.worldBooks.isEmpty {
                ContentUnavailableView(
                    L10n.lookup("还没有世界书"),
                    systemImage: "book",
                    description: Text(L10n.lookup("世界书条目按关键词触发，把设定注入到对话里"))
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(model.worldBooks) { book in
                        HStack(spacing: 12) {
                            Button {
                                editingBook = book
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(book.name.isEmpty ? L10n.lookup("未命名世界书") : book.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(L10n.format("%@ 个条目", [String(describing: book.entries.count)]))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Toggle(
                                L10n.lookup("对当前助手启用"),
                                isOn: Binding(
                                    get: { model.isWorldBookActive(book.id) },
                                    set: { _ in model.toggleWorldBookActive(book.id) }
                                )
                            )
                            .labelsHidden()
                        }
                    }
                    .onDelete { offsets in
                        for offset in offsets.sorted(by: >)
                        where model.worldBooks.indices.contains(offset) {
                            model.deleteWorldBook(model.worldBooks[offset].id)
                        }
                    }
                } footer: {
                    Text(L10n.format("开关只对当前助手「%@」生效", [String(describing: model.currentAssistant.name)]))
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("世界书"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingBook = WorldBook()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.lookup("新建世界书"))
            }
        }
        .sheet(item: $editingBook) { book in
            WorldBookEditorView(book: book) { saved in
                model.upsertWorldBook(saved)
            }
        }
    }
}

private struct WorldBookEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var book: WorldBook
    @State private var editingEntry: WorldBookEntry?
    let onSave: (WorldBook) -> Void

    init(book: WorldBook, onSave: @escaping (WorldBook) -> Void) {
        _book = State(initialValue: book)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.lookup("基本信息")) {
                    TextField(L10n.lookup("世界书名称"), text: $book.name)
                    TextField(L10n.lookup("描述（可选）"), text: $book.description)
                    Toggle(L10n.lookup("启用"), isOn: $book.enabled)
                }

                Section {
                    ForEach(book.entries) { entry in
                        Button {
                            editingEntry = entry
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(entry.name.isEmpty ? L10n.lookup("未命名条目") : entry.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if entry.constantActive {
                                        Text(L10n.lookup("常驻"))
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    }
                                    if !entry.enabled {
                                        Text(L10n.lookup("已停用"))
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(entry.keywords.isEmpty ? L10n.lookup("无关键词") : entry.keywords.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        book.entries.remove(atOffsets: offsets)
                    }

                    Button {
                        editingEntry = WorldBookEntry()
                    } label: {
                        Label(L10n.lookup("新建条目"), systemImage: "plus")
                    }
                } header: {
                    Text(L10n.lookup("条目"))
                }
            }
            .settingsGroupedPageStyle()
            .navigationTitle(book.name.isEmpty ? L10n.lookup("世界书") : book.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消")) { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("保存")) {
                        onSave(book)
                        dismiss()
                    }
                        .foregroundStyle(.primary)
                }
            }
            .sheet(item: $editingEntry) { entry in
                WorldBookEntryEditorView(entry: entry) { saved in
                    if let index = book.entries.firstIndex(where: { $0.id == saved.id }) {
                        book.entries[index] = saved
                    } else {
                        book.entries.append(saved)
                    }
                }
            }
        }
    }
}

private struct WorldBookKeywordFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var usedHeight: CGFloat = 0

        for subview in subviews {
            let size = itemSize(for: subview, maximumWidth: maximumWidth)
            let spacing = rowWidth == 0 ? 0 : horizontalSpacing
            if rowWidth > 0, rowWidth + spacing + size.width > maximumWidth {
                usedWidth = max(usedWidth, rowWidth)
                usedHeight += rowHeight + verticalSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += spacing + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }

        usedWidth = max(usedWidth, rowWidth)
        usedHeight += rowHeight
        return CGSize(width: min(usedWidth, maximumWidth), height: usedHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = itemSize(for: subview, maximumWidth: bounds.width)
            let proposedX = x == bounds.minX ? x : x + horizontalSpacing
            if x > bounds.minX, proposedX + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            } else {
                x = proposedX
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func itemSize(for subview: LayoutSubview, maximumWidth: CGFloat) -> CGSize {
        let naturalSize = subview.sizeThatFits(.unspecified)
        guard maximumWidth.isFinite else { return naturalSize }
        let width = min(naturalSize.width, maximumWidth)
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}

private struct WorldBookKeywordChip: View {
    let keyword: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(keyword)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("删除关键词 %@", [String(describing: keyword)]))
        }
        .foregroundStyle(.primary)
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(minHeight: 36)
        .background(Capsule().fill(Color.accentColor.opacity(0.11)))
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.24), lineWidth: 0.8))
    }
}

private struct WorldBookEntryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entry: WorldBookEntry
    @State private var keywords: [String]
    @State private var keywordDraft = ""
    let onSave: (WorldBookEntry) -> Void

    init(entry: WorldBookEntry, onSave: @escaping (WorldBookEntry) -> Void) {
        _entry = State(initialValue: entry)
        _keywords = State(initialValue: Self.splitKeywords(entry.keywords.joined(separator: ",")))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.lookup("基本信息")) {
                    TextField(L10n.lookup("条目名称"), text: $entry.name)
                    Toggle(L10n.lookup("启用"), isOn: $entry.enabled)
                    Toggle(L10n.lookup("常驻激活"), isOn: $entry.constantActive)
                }

                if !entry.constantActive {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            if !keywords.isEmpty {
                                WorldBookKeywordFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                                    ForEach(Array(keywords.enumerated()), id: \.offset) { index, keyword in
                                        WorldBookKeywordChip(keyword: keyword) {
                                            removeKeyword(at: index)
                                        }
                                    }
                                }
                            }

                            HStack(spacing: 10) {
                                TextField(L10n.lookup("输入关键词"), text: $keywordDraft)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .submitLabel(.done)
                                    .onSubmit(addKeywordDraft)

                                Button(action: addKeywordDraft) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 16, weight: .semibold))
                                        .frame(width: 40, height: 36)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(Color.primary.opacity(0.055))
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(Self.splitKeywords(keywordDraft).isEmpty)
                                .accessibilityLabel(L10n.lookup("添加关键词"))
                            }
                        }
                        .padding(.vertical, 3)

                        Toggle(L10n.lookup("正则匹配"), isOn: $entry.useRegex)
                        Toggle(L10n.lookup("区分大小写"), isOn: $entry.caseSensitive)
                        Stepper(L10n.format("扫描最近 %@ 条消息", [String(describing: entry.scanDepth)]), value: $entry.scanDepth, in: 1...50)
                        Stepper(
                            entry.injectionRounds == 0
                                ? L10n.lookup("持续轮数：跟随扫描范围")
                                : L10n.format("持续轮数：%@ 轮", [String(describing: entry.injectionRounds)]),
                            value: $entry.injectionRounds,
                            in: 0...50
                        )
                    } header: {
                        Text(L10n.lookup("触发关键词"))
                    } footer: {
                        Text(L10n.lookup("0 表示只要关键词仍在扫描范围内就保持激活；大于 0 时，命中关键词后会持续到对应的用户轮数。"))
                    }
                }

                Section(L10n.lookup("注入")) {
                    Picker(L10n.lookup("位置"), selection: $entry.position) {
                        ForEach(WorldBookInjectionPosition.allCases) { position in
                            Text(L10n.lookup(position.title)).tag(position)
                        }
                    }
                    if entry.position == .atDepth {
                        Stepper(L10n.format("深度 %@", [String(describing: entry.injectDepth)]), value: $entry.injectDepth, in: 1...50)
                    }
                    if entry.position == .topOfChat || entry.position == .bottomOfChat
                        || entry.position == .atDepth {
                        Picker(L10n.lookup("身份"), selection: $entry.role) {
                            ForEach(WorldBookInjectionRole.allCases) { role in
                                Text(L10n.lookup(role.title)).tag(role)
                            }
                        }
                    }
                    Stepper(L10n.format("优先级 %@", [String(describing: entry.priority)]), value: $entry.priority, in: -100...100)
                }

                Section(L10n.lookup("内容")) {
                    NativeMultilineTextEditor(
                        text: $entry.content,
                        font: .system(size: 16)
                    )
                        .frame(minHeight: 150)
                }
            }
            .settingsGroupedPageStyle()
            .navigationTitle(entry.name.isEmpty ? L10n.lookup("条目") : entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消")) { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("保存")) {
                        entry.keywords = keywordsForSaving
                        onSave(entry)
                        dismiss()
                    }
                        .foregroundStyle(.primary)
                    .disabled(entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var keywordsForSaving: [String] {
        var result = keywords
        for keyword in Self.splitKeywords(keywordDraft) where !result.contains(keyword) {
            result.append(keyword)
        }
        return result
    }

    private func addKeywordDraft() {
        let additions = Self.splitKeywords(keywordDraft)
        guard !additions.isEmpty else { return }
        for keyword in additions where !keywords.contains(keyword) {
            keywords.append(keyword)
        }
        keywordDraft = ""
    }

    private func removeKeyword(at index: Int) {
        guard keywords.indices.contains(index) else { return }
        keywords.remove(at: index)
    }

    private static func splitKeywords(_ text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ",，"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
