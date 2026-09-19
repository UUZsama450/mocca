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
    @State private var photoSelection: PhotosPickerItem?

    private var themeAccentColor: Color {
        Color(uiColor: model.themeAccentUIColor)
    }

    private var themeActionColor: Color {
        Color(uiColor: model.themeActionUIColor)
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    profileHeader
                    enabledSection
                    ProfileCard(title: "自定义偏好") {
                        ProfileTextArea(
                            title: "个人喜好和兴趣",
                            text: profileTextBinding(\.interests)
                        )
                        ProfileTextArea(
                            title: "不希望主动提到",
                            text: profileTextBinding(\.avoidTopics)
                        )
                        ProfileTextArea(
                            title: "补充说明",
                            text: profileTextBinding(\.additionalNotes)
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("个人资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(.primary)
                }
            }
            .onChange(of: photoSelection) { _, item in
                guard let item else { return }
                photoSelection = nil
                Task { @MainActor in
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    model.setUserProfileAvatar(image)
                }
            }
        }
        .tint(themeActionColor)
    }

    private var profileHeader: some View {
        let currentProfile = model.userProfile
        let accentColor = themeAccentColor
        return ProfileCard {
            HStack(spacing: 18) {
                PhotosPicker(selection: $photoSelection, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        UserProfileAvatarView(profile: currentProfile, size: 78)
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 24))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, accentColor)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if model.userProfile.avatarJPEGData != nil {
                        Button("移除头像", systemImage: "trash", role: .destructive) {
                            model.clearUserProfileAvatar()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("昵称")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(UserProfile.defaultNickname, text: profileTextBinding(\.nickname))
                        .font(.system(size: 20))
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 12)
                        .frame(height: 52)
                        .profileInputSurface()
                }
            }
        }
    }

    private var enabledSection: some View {
        ProfileCard {
            Toggle(isOn: profileBoolBinding(\.isEnabled)) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("在聊天中使用个人资料")
                        .font(.headline)
                    Text("开启后会把个人资料放在靠近最新消息的位置，尽量不扰动助手提示词缓存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func profileTextBinding(_ keyPath: WritableKeyPath<UserProfile, String>) -> Binding<String> {
        Binding(
            get: { model.userProfile[keyPath: keyPath] },
            set: { model.setUserProfileText(keyPath, value: $0) }
        )
    }

    private func profileBoolBinding(_ keyPath: WritableKeyPath<UserProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.userProfile[keyPath: keyPath] },
            set: { model.setUserProfileBool(keyPath, value: $0) }
        )
    }
}

private struct ProfileTextArea: View {
    let title: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.medium))
            NativeMultilineTextEditor(text: $text)
                .frame(minHeight: 88)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .profileInputSurface()
        }
    }
}

private struct ProfileInputSurfaceModifier: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(0.04), in: shape)
            .overlay {
                shape.stroke(Color.primary.opacity(0.09), lineWidth: 0.7)
            }
            .contentShape(shape)
    }
}

private extension View {
    func profileInputSurface() -> some View {
        modifier(ProfileInputSurfaceModifier())
    }
}

private struct ProfileCard<Content: View>: View {
    let title: LocalizedStringKey?
    let content: Content

    init(title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
