import SwiftUI

struct SponsorPage: View {
    @Environment(AppModel.self) private var model
    @State private var store = SponsorStore.shared
    @State private var unlockedEasterEggs: [SponsorWardrobeItem] = []
    @State private var selectedEasterEgg: SponsorWardrobeItem?
    @State private var easterEggWearer: SponsorAvatarWearer = .none

    private var accentColor: Color {
        Color(uiColor: model.themeAccentUIColor)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                thankYouCard
                supportOptions
                statisticsCard
                easterEggWardrobe
                purchaseRecovery
                purchaseNote
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(L10n.lookup("赞助"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.prepare()
        }
        .task {
            refreshEasterEggWardrobe()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sponsorEasterEggDidChange)) { _ in
            refreshEasterEggWardrobe()
        }
    }

    private var thankYouCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accentColor.opacity(0.17), Color.pink.opacity(0.09)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 10) {
                SponsorWearableAvatar(target: .user, badgeSize: 28) {
                    UserProfileAvatarView(profile: model.userProfile, size: 68)
                }
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.86), lineWidth: 3)
                    }
                    .shadow(color: accentColor.opacity(0.2), radius: 10, y: 4)
                    .scaleEffect(store.celebration == nil ? 1 : 1.07)
                    .animation(.spring(response: 0.32, dampingFraction: 0.68), value: store.celebration?.id)

                Text(L10n.lookup("谢谢你愿意喜欢 Mocca"))
                    .font(.title3.weight(.semibold))

                Text(store.statusMessage ?? L10n.lookup("每一份投喂都会变成继续把它做好的动力。"))
                    .font(.subheadline)
                    .foregroundStyle(store.statusIsError ? Color.red : Color.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 290)

                if let message = store.productLoadingMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 290)
                }

                if store.hasMissingProducts {
                    Button(L10n.lookup("重新载入")) {
                        Task { await store.retryLoadingProducts() }
                    }
                    .font(.subheadline.weight(.medium))
                    .disabled(store.isLoadingProducts || store.purchasingTier != nil || store.isRestoringPurchases)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)

            if let celebration = store.celebration {
                SponsorCelebrationView(event: celebration)
                    .id(celebration.id)
            }
        }
        .frame(minHeight: 210)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(accentColor.opacity(0.1), lineWidth: 0.8)
        }
        .accessibilityElement(children: .combine)
    }

    private var supportOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            SponsorSectionTitle(title: L10n.lookup("投喂一下"), subtitle: L10n.lookup("自愿赞助 · 装扮仅作装饰"))

            VStack(spacing: 0) {
                ForEach(Array(SponsorTier.allCases.enumerated()), id: \.element.id) { index, tier in
                    supportButton(for: tier)
                    if index < SponsorTier.allCases.count - 1 {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .sponsorSurface()
        }
    }

    private func supportButton(for tier: SponsorTier) -> some View {
        let product = store.product(for: tier)
        let isPurchasing = store.purchasingTier == tier
        return Button {
            Task { await store.purchase(tier) }
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(tier.tint.opacity(0.14))
                    Image(systemName: tier.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tier.tint)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.lookup(tier.title))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(tier.wardrobeRewardDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                if isPurchasing {
                    ProgressView()
                        .controlSize(.small)
                } else if let product {
                    Text(product.displayPrice)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tier.tint)
                } else if store.isLoadingProducts {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(L10n.lookup("暂不可用"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(product == nil || store.purchasingTier != nil || store.isRestoringPurchases)
        .accessibilityHint(
            L10n.format("打开 App Store 购买确认。首次投喂解锁小水滴和%@永久纪念装扮；重复购买不会增加新装扮", [L10n.lookup(tier.chatBadgeName)])
        )
    }

    private var purchaseRecovery: some View {
        Button {
            model.performCardHaptic()
            Task { await store.restorePurchases() }
        } label: {
            HStack(spacing: 11) {
                Group {
                    if store.isRestoringPurchases {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise.icloud")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(accentColor)
                    }
                }
                .frame(width: 28, height: 28)
                .background(accentColor.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isRestoringPurchases ? L10n.lookup("正在恢复购买…") : L10n.lookup("恢复购买"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(L10n.lookup("找回这个 Apple Account 已购买的纪念装扮"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.purchasingTier != nil || store.isRestoringPurchases)
        .accessibilityLabel(L10n.lookup("恢复购买"))
        .accessibilityHint(L10n.lookup("向 App Store 同步以前的投喂记录，不会产生新的购买"))
        .sponsorSurface()
    }

    @ViewBuilder
    private var statisticsCard: some View {
        if store.statistics.total > 0 {
            VStack(alignment: .leading, spacing: 10) {
                SponsorSectionTitle(title: L10n.lookup("我的投喂"), subtitle: L10n.lookup("由 App Store 验证的购买次数"))

                VStack(spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.lookup("已经被投喂"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(store.statistics.total)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(accentColor)
                        Text(L10n.lookup("次啦"))
                            .font(.subheadline.weight(.medium))
                    }

                    HStack(spacing: 8) {
                        ForEach(SponsorTier.allCases) { tier in
                            VStack(spacing: 4) {
                                Image(systemName: tier.systemImage)
                                    .foregroundStyle(tier.tint)
                                Text("\(store.statistics[tier])")
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                Text(L10n.lookup(tier.subtitle))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(15)
                .sponsorSurface()
            }
        }
    }

    @ViewBuilder
    private var easterEggWardrobe: some View {
        if !unlockedEasterEggs.isEmpty, let selectedEasterEgg {
            VStack(alignment: .leading, spacing: 9) {
                SponsorSectionTitle(title: L10n.lookup("彩蛋衣柜"), subtitle: L10n.lookup("永久纪念装扮 · 无功能加成"))

                VStack(spacing: 15) {
                    Text(L10n.lookup("喜欢新聊天里掉下来的小家伙，就选一个头像让它住下吧。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        ForEach(unlockedEasterEggs) { item in
                            Button {
                                model.performCardHaptic()
                                SponsorEasterEggPersistence.select(item)
                            } label: {
                                Text(item.emoji)
                                    .font(.system(size: 24))
                                    .frame(width: 48, height: 42)
                                    .background(
                                        item == selectedEasterEgg
                                            ? item.tint.opacity(0.16)
                                            : Color.secondary.opacity(0.08),
                                        in: Capsule()
                                    )
                                    .overlay {
                                        Capsule()
                                            .stroke(
                                                item == selectedEasterEgg
                                                    ? item.tint.opacity(0.55)
                                                    : Color.clear,
                                                lineWidth: 1.2
                                            )
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.format("选择%@彩蛋", [L10n.lookup(item.name)]))
                            .accessibilityAddTraits(
                                item == selectedEasterEgg ? .isSelected : []
                            )
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 12) {
                        wardrobeAvatarButton(
                            wearer: .assistant,
                            title: L10n.lookup("给助手戴"),
                            item: selectedEasterEgg
                        )
                        wardrobeAvatarButton(
                            wearer: .user,
                            title: L10n.lookup("给我戴"),
                            item: selectedEasterEgg
                        )
                    }

                    Button {
                        model.performCardHaptic()
                        SponsorEasterEggPersistence.setWearer(.none)
                    } label: {
                        Label(
                            easterEggWearer == .none ? L10n.lookup("先收在衣柜里") : L10n.lookup("暂时不戴"),
                            systemImage: easterEggWearer == .none
                                ? "checkmark.circle.fill"
                                : "tray"
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(
                            easterEggWearer == .none ? accentColor : Color.secondary
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(15)
                .sponsorSurface()
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func wardrobeAvatarButton(
        wearer: SponsorAvatarWearer,
        title: String,
        item: SponsorWardrobeItem
    ) -> some View {
        Button {
            model.performCardHaptic()
            SponsorEasterEggPersistence.setWearer(wearer)
        } label: {
            VStack(spacing: 8) {
                SponsorBadgedAvatar(
                    item: easterEggWearer == wearer ? item : nil,
                    badgeSize: 22
                ) {
                    if wearer == .assistant {
                        AssistantAvatarView(profile: model.currentAssistant, size: 52)
                    } else {
                        UserProfileAvatarView(profile: model.userProfile, size: 52)
                    }
                }

                HStack(spacing: 4) {
                    Text(title)
                    if easterEggWearer == wearer {
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
                .font(.caption.weight(.semibold))
            }
            .foregroundStyle(easterEggWearer == wearer ? accentColor : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                easterEggWearer == wearer
                    ? accentColor.opacity(0.10)
                    : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(easterEggWearer == wearer ? .isSelected : [])
    }

    private var purchaseNote: some View {
        Text(L10n.lookup("投喂完全自愿，不影响聊天能力，也不会自动续费。任意档位首次投喂都会解锁 💧 小水滴；各档另会解锁页面标注的永久纪念装扮。所有装扮均为没有功能加成的纯装饰。同一档可以重复投喂，但不会重复增加装扮；每次购买都会由 App Store 单独确认。"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
    }

    @MainActor
    private func refreshEasterEggWardrobe() {
        withAnimation(.easeInOut(duration: 0.2)) {
            unlockedEasterEggs = SponsorEasterEggPersistence.unlockedWardrobeItems
            selectedEasterEgg = SponsorEasterEggPersistence.selectedWardrobeItem
            easterEggWearer = SponsorEasterEggPersistence.wearer
        }
    }
}

private struct SponsorSectionTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let subtitle {
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct SponsorCelebrationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let event: SponsorCelebration

    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: "heart.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(event.tier.tint)
                    .transition(.opacity)
            } else {
                switch event.tier {
                case .treat:
                    SponsorFirework(
                        count: 9,
                        radius: 76,
                        duration: 0.72,
                        symbols: ["sparkle"],
                        colors: [.yellow, .orange, .pink]
                    )
                case .drink:
                    SponsorFirework(
                        count: 15,
                        radius: 96,
                        duration: 1.02,
                        symbols: ["circle.fill", "sparkle"],
                        colors: [.pink, .purple, .cyan, .yellow]
                    )
                case .feast:
                    ZStack {
                        SponsorFirework(
                            count: 15,
                            radius: 90,
                            duration: 1.18,
                            symbols: ["heart.fill", "sparkle", "circle.fill"],
                            colors: [.pink, .red, .yellow, .purple]
                        )
                        .offset(x: -48, y: 4)
                        SponsorFirework(
                            count: 14,
                            radius: 86,
                            duration: 1.28,
                            symbols: ["sparkle", "circle.fill", "heart.fill"],
                            colors: [.cyan, .yellow, .pink, .orange]
                        )
                        .offset(x: 52, y: -20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SponsorFirework: View {
    let count: Int
    let radius: CGFloat
    let duration: Double
    let symbols: [String]
    let colors: [Color]

    @State private var expanded = false

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                let angle = (Double(index) / Double(max(count, 1))) * Double.pi * 2 - Double.pi / 2
                let distance = radius * (0.78 + CGFloat(index % 4) * 0.075)
                Image(systemName: symbols[index % symbols.count])
                    .font(.system(size: index.isMultiple(of: 3) ? 11 : 8, weight: .bold))
                    .foregroundStyle(colors[index % colors.count])
                    .scaleEffect(expanded ? 0.55 : 0.2)
                    .opacity(expanded ? 0 : 1)
                    .offset(
                        x: expanded ? cos(angle) * distance : 0,
                        y: expanded ? sin(angle) * distance : 0
                    )
                    .rotationEffect(.degrees(expanded ? Double(index * 31) : 0))
                    .animation(
                        .easeOut(duration: duration).delay(Double(index % 4) * 0.025),
                        value: expanded
                    )
            }
        }
        .onAppear {
            expanded = true
        }
    }
}

struct SponsorBadgedAvatar<Content: View>: View {
    let item: SponsorWardrobeItem?
    let badgeSize: CGFloat
    private let content: Content

    init(
        item: SponsorWardrobeItem?,
        badgeSize: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.item = item
        self.badgeSize = badgeSize
        self.content = content()
    }

    var body: some View {
        content.overlay(alignment: .topTrailing) {
            if let item {
                SponsorAvatarBadgeIcon(item: item, size: badgeSize)
                    .offset(x: badgeSize * 0.06, y: -badgeSize * 0.06)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
    }
}

struct SponsorAvatarBadgeIcon: View {
    let item: SponsorWardrobeItem
    let size: CGFloat

    var body: some View {
        Text(item.emoji)
            .font(.system(size: max(10, size * (item.usesCircle ? 0.54 : 0.82))))
            .frame(width: size, height: size)
            .background {
                if item.usesCircle {
                    Circle().fill(.thinMaterial)
                }
            }
            .overlay {
                if item.usesCircle {
                    Circle()
                        .stroke(.white.opacity(0.72), lineWidth: 0.8)
                }
            }
            .shadow(
                color: .black.opacity(item.usesCircle ? 0.15 : 0.08),
                radius: item.usesCircle ? 3 : 1.5,
                y: item.usesCircle ? 1.5 : 0.5
            )
    }
}

struct SponsorWearableAvatar<Content: View>: View {
    let target: SponsorAvatarWearer
    let badgeSize: CGFloat
    private let content: Content
    @State private var item: SponsorWardrobeItem?

    init(
        target: SponsorAvatarWearer,
        badgeSize: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.target = target
        self.badgeSize = badgeSize
        self.content = content()
    }

    var body: some View {
        SponsorBadgedAvatar(item: item, badgeSize: badgeSize) {
            content
        }
        .task {
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sponsorEasterEggDidChange)) { _ in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                refresh()
            }
        }
    }

    @MainActor
    private func refresh() {
        item = SponsorEasterEggPersistence.wornWardrobeItem(for: target)
    }
}

private extension SponsorTier {
    var tint: Color {
        switch self {
        case .treat: .orange
        case .drink: .pink
        case .feast: .purple
        }
    }
}

private extension SponsorWardrobeItem {
    var tint: Color {
        switch self {
        case .droplet: .cyan
        case .treat: SponsorTier.treat.tint
        case .drink: SponsorTier.drink.tint
        case .feast: SponsorTier.feast.tint
        }
    }
}

private extension View {
    func sponsorSurface() -> some View {
        background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.secondary.opacity(0.08), lineWidth: 0.7)
            }
    }
}
