import PhotosUI
import SwiftUI
import UIKit

struct UserProfileAvatarView: View {
    @Environment(AppModel.self) private var model
    let profile: UserProfile
    var size: CGFloat = 44

    private var themeAccentColor: Color {
        Color(uiColor: model.themeAccentUIColor)
    }

    var body: some View {
        Group {
            if let data = profile.avatarJPEGData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(themeAccentColor.opacity(0.12))
                    Image("DefaultUserAvatar")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(themeAccentColor)
                        .padding(size * 0.16)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct UserProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var baseline: UserProfile
    @State private var draft: UserProfile
    @State private var expanded = Set<UUID>()
    @State private var photoSelection: PhotosPickerItem?
    @State private var photoTask: Task<Void, Never>?
    @State private var topicName = ""
    @State private var topicToRename: UUID?
    @State private var isTopicEditorPresented = false
    @State private var isLeaveConfirmationPresented = false
    @State private var isConflictPresented = false
    @State private var errorMessage: String?
    @State private var exitClosesSettings = false
    @State private var undo: DeletedContent?
    @FocusState private var focusedNote: UUID?
    private let onCloseSettings: () -> Void

    private enum DeletedContent {
        case topic(UserNoteTopic, Int)
        case note(UserNote, UUID, Int)
    }

    init(profile: UserProfile, onCloseSettings: @escaping () -> Void) {
        _baseline = State(initialValue: profile)
        _draft = State(initialValue: profile)
        self.onCloseSettings = onCloseSettings
    }

    private var hasUnsavedChanges: Bool {
        var normalized = draft
        normalized.normalize()
        return normalized != baseline
    }

    private var hasEmptyContent: Bool {
        draft.noteTopics.contains {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.notes.contains { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    var body: some View {
        List {
            Section { profileHeader }
                .listRowSeparator(.hidden)
            Section {
                Toggle(isOn: $draft.isEnabled) {
                    permissionLabel("在聊天中使用资料", detail: "让助手参考你的个人资料")
                }
                .accessibilityIdentifier("profile.enabled")
                Toggle(isOn: $draft.allowsAssistantEditing) {
                    permissionLabel("允许助手编辑", detail: "可新增主题、添加、修改和删除条目")
                }
                .disabled(!draft.isEnabled)
                .accessibilityIdentifier("profile.assistantEditing")
            }
            if draft.noteTopics.isEmpty {
                Section {
                    Text(L10n.lookup("点 ＋ 添加第一个主题"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                } header: {
                    notesHeader
                }
            }
            ForEach($draft.noteTopics) { $topic in
                Section {
                    topicHeader($topic)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(L10n.lookup("删除"), role: .destructive) { deleteTopic(topic.id) }
                        }
                        .accessibilityAction(named: Text(L10n.lookup("删除主题"))) { deleteTopic(topic.id) }
                    if expanded.contains(topic.id) {
                        if topic.notes.isEmpty {
                            Text(L10n.lookup("还没有内容，点 ＋ 添加一条"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach($topic.notes) { $note in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\((topic.notes.firstIndex { $0.id == note.id } ?? 0) + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                    .padding(.top, 12)
                                TextField(L10n.lookup("写下一条具体内容…"), text: $note.content, axis: .vertical)
                                    .font(.body)
                                    .padding(.vertical, 9)
                                    .focused($focusedNote, equals: note.id)
                                    .accessibilityIdentifier("profile.note.\(note.id)")
                                Button {
                                    deleteNote(note.id, topicID: topic.id)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L10n.lookup("删除条目"))
                            }
                            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 8))
                        }
                    }
                } header: {
                    if topic.id == draft.noteTopics.first?.id {
                        notesHeader
                    }
                }
            }
            if undo != nil {
                Section {
                    HStack {
                        Text(L10n.lookup("已删除"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.lookup("撤销"), action: undoDeletion)
                    }
                    .font(.subheadline)
                }
            }
        }
        .settingsGroupedPageStyle()
        .listSectionSpacing(12)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(L10n.lookup("个人资料"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .toolbar {
            if hasUnsavedChanges {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        requestLeave(closesSettings: false)
                    } label: {
                        Label(L10n.lookup("设置"), systemImage: "chevron.left")
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("profile.back")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    focusedNote = nil
                    exitClosesSettings = false
                    saveAndLeave()
                } label: {
                    HStack(spacing: 5) {
                        if hasUnsavedChanges {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                        Text(L10n.lookup("保存"))
                    }
                }
                .foregroundStyle(.primary)
                .disabled(hasEmptyContent)
                .accessibilityLabel(L10n.lookup("保存"))
                .accessibilityValue(hasUnsavedChanges ? L10n.lookup("有修改尚未保存") : "")
                .accessibilityIdentifier("profile.save")
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .background {
            DraftDismissObserver(hasUnsavedChanges: hasUnsavedChanges) {
                requestLeave(closesSettings: true)
            }
            DraftNavigationGuard(hasUnsavedChanges: hasUnsavedChanges) {
                requestLeave(closesSettings: false)
            }
        }
        .alert(L10n.lookup(topicToRename == nil ? "添加主题" : "修改主题名称"), isPresented: $isTopicEditorPresented) {
            TextField(L10n.lookup("主题名称"), text: $topicName)
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(L10n.lookup(topicToRename == nil ? "添加" : "保存"), action: commitTopicName)
                .disabled(topicName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .background {
            DraftExitConfirmation(
                isPresented: $isLeaveConfirmationPresented,
                title: L10n.lookup("保存对个人资料的修改？"),
                onSave: saveAndLeave,
                onDiscard: leave,
                message: L10n.lookup(hasEmptyContent ? "请填写或删除空白条目后保存。" : "你的修改尚未保存。"),
                saveEnabled: !hasEmptyContent
            )
        }
        .alert(L10n.lookup("便签已在其他地方更新"), isPresented: $isConflictPresented) {
            Button(L10n.lookup("继续编辑"), role: .cancel) {}
            Button(L10n.lookup("放弃草稿并载入最新资料"), role: .destructive, action: reloadProfile)
        } message: {
            Text(L10n.lookup("同一项内容有新的修改，草稿已保留，尚未覆盖最新资料。"))
        }
        .alert(L10n.lookup("无法保存个人资料"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.lookup("好"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            photoSelection = nil
            photoTask?.cancel()
            photoTask = Task { @MainActor in
                guard let data = try? await item.loadTransferable(type: Data.self),
                      !Task.isCancelled, let image = UIImage(data: data),
                      let jpeg = UserProfile.jpegData(from: image) else { return }
                draft.avatarJPEGData = jpeg
            }
        }
        .onChange(of: model.userProfile) { _, _ in
            if !hasUnsavedChanges { reloadProfile() }
        }
        .onDisappear { photoTask?.cancel() }
    }

    private var notesHeader: some View {
        HStack(spacing: 12) {
            Text(L10n.lookup("便签"))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button {
                topicToRename = nil
                topicName = ""
                isTopicEditorPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(L10n.lookup("添加主题"))
            .accessibilityIdentifier("profile.addTopic")
        }
        .textCase(nil)
    }

    private var profileHeader: some View {
        HStack(spacing: 18) {
            PhotosPicker(selection: $photoSelection, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    SponsorWearableAvatar(target: .user, badgeSize: 19) {
                        UserProfileAvatarView(profile: draft, size: 70)
                    }
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 23))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(uiColor: model.themeAccentUIColor))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.lookup("更换头像"))
            .contextMenu {
                if draft.avatarJPEGData != nil {
                    Button(L10n.lookup("移除头像"), systemImage: "trash", role: .destructive) {
                        photoTask?.cancel()
                        draft.avatarJPEGData = nil
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.lookup("昵称")).font(.caption).foregroundStyle(.secondary)
                TextField(L10n.lookup("昵称"), text: $draft.nickname)
                    .font(.system(size: 20))
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12)
                    .frame(height: 52)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("profile.nickname")
            }
        }
        .padding(.vertical, 4)
    }

    private func permissionLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.lookup(title)).font(.body)
            Text(L10n.lookup(detail)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func topicHeader(_ topic: Binding<UserNoteTopic>) -> some View {
        let value = topic.wrappedValue
        let isExpanded = expanded.contains(value.id)
        return HStack(spacing: 0) {
            Button {
                if isExpanded { expanded.remove(value.id) } else { expanded.insert(value.id) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(value.title).font(.body.weight(.medium))
                    Text(L10n.format("%@ 条", [String(value.notes.count)]))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(L10n.lookup(isExpanded ? "已展开" : "已收起"))
            .accessibilityIdentifier("profile.topic.\(value.id)")
            if isExpanded {
                Button {
                    topicToRename = value.id
                    topicName = value.title
                    isTopicEditorPresented = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.lookup("修改主题名称"))
            }
            Button {
                let note = UserNote(content: "")
                topic.wrappedValue.notes.append(note)
                expanded.insert(value.id)
                focusedNote = note.id
            } label: {
                Image(systemName: "plus").font(.system(size: 18))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .accessibilityLabel(L10n.lookup("添加条目"))
            .accessibilityIdentifier("profile.addNote.\(value.id)")
        }
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 6))
    }

    private func commitTopicName() {
        let title = topicName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if let id = topicToRename, let index = draft.noteTopics.firstIndex(where: { $0.id == id }) {
            draft.noteTopics[index].title = title
        } else {
            let topic = UserNoteTopic(title: title)
            draft.noteTopics.append(topic)
            expanded.insert(topic.id)
        }
    }

    private func deleteTopic(_ id: UUID) {
        guard let index = draft.noteTopics.firstIndex(where: { $0.id == id }) else { return }
        undo = .topic(draft.noteTopics.remove(at: index), index)
        expanded.remove(id)
    }

    private func deleteNote(_ id: UUID, topicID: UUID) {
        guard let topicIndex = draft.noteTopics.firstIndex(where: { $0.id == topicID }),
              let index = draft.noteTopics[topicIndex].notes.firstIndex(where: { $0.id == id }) else { return }
        undo = .note(draft.noteTopics[topicIndex].notes.remove(at: index), topicID, index)
    }

    private func undoDeletion() {
        switch undo {
        case .topic(let topic, let index):
            draft.noteTopics.insert(topic, at: min(index, draft.noteTopics.count))
            expanded.insert(topic.id)
        case .note(let note, let topicID, let index):
            if let at = draft.noteTopics.firstIndex(where: { $0.id == topicID }) {
                draft.noteTopics[at].notes.insert(note, at: min(index, draft.noteTopics[at].notes.count))
                expanded.insert(topicID)
            }
        case nil: break
        }
        undo = nil
    }

    private func requestLeave(closesSettings: Bool) {
        focusedNote = nil
        exitClosesSettings = closesSettings
        if hasUnsavedChanges { isLeaveConfirmationPresented = true } else { leave() }
    }

    private func leave() {
        photoTask?.cancel()
        if exitClosesSettings { onCloseSettings() } else { dismiss() }
    }

    private func saveAndLeave() {
        guard !hasEmptyContent else { return }
        do {
            try model.commitUserProfileDraft(draft, baseline: baseline)
            leave()
        } catch UserProfileEditError.conflict {
            isConflictPresented = true
        } catch {
            errorMessage = L10n.lookup("个人资料没有保存成功，请重试。")
        }
    }

    private func reloadProfile() {
        baseline = model.userProfile
        draft = model.userProfile
        undo = nil
    }
}
