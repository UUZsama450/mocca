import Foundation
import Observation
import OSLog
import StoreKit

enum SponsorTier: String, CaseIterable, Identifiable, Sendable {
    case treat
    case drink
    case feast

    var id: String { rawValue }

    var productID: String {
        switch self {
        case .treat:
            "com.uuzsama450.mocca.support.small"
        case .drink:
            "com.uuzsama450.mocca.support.medium"
        case .feast:
            "com.uuzsama450.mocca.support.large"
        }
    }

    var title: String {
        switch self {
        case .treat: "请我吃颗糖"
        case .drink: "请我喝杯奶茶"
        case .feast: "请我吃顿好的"
        }
    }

    var subtitle: String {
        switch self {
        case .treat: "小小投喂"
        case .drink: "暖心投喂"
        case .feast: "超级投喂"
        }
    }

    @MainActor var wardrobeRewardDescription: String {
        L10n.format("首次送 💧＋%@ 纪念装扮", [chatBadgeEmoji])
    }

    var systemImage: String {
        switch self {
        case .treat: "sparkles"
        case .drink: "cup.and.saucer.fill"
        case .feast: "heart.fill"
        }
    }

    var chatBadgeEmoji: String {
        switch self {
        case .treat: "🍬"
        case .drink: "🧋"
        case .feast: "🍱"
        }
    }

    var chatBadgeName: String {
        switch self {
        case .treat: "糖果"
        case .drink: "奶茶"
        case .feast: "大餐"
        }
    }

    var thankYou: String {
        switch self {
        case .treat: "收到一颗甜甜的糖，谢谢你！"
        case .drink: "奶茶到手啦，谢谢你的暖心投喂！"
        case .feast: "今天可以吃顿好的啦，特别谢谢你！"
        }
    }

    static let productIDs = Set(allCases.map(\.productID))
}

enum SponsorWardrobeItem: String, CaseIterable, Identifiable, Sendable {
    case droplet
    case treat
    case drink
    case feast

    var id: String { rawValue }

    init(tier: SponsorTier) {
        switch tier {
        case .treat: self = .treat
        case .drink: self = .drink
        case .feast: self = .feast
        }
    }

    var tier: SponsorTier? {
        switch self {
        case .droplet: nil
        case .treat: .treat
        case .drink: .drink
        case .feast: .feast
        }
    }

    var emoji: String {
        switch self {
        case .droplet: "💧"
        case .treat: SponsorTier.treat.chatBadgeEmoji
        case .drink: SponsorTier.drink.chatBadgeEmoji
        case .feast: SponsorTier.feast.chatBadgeEmoji
        }
    }

    var name: String {
        switch self {
        case .droplet: "小水滴"
        case .treat: SponsorTier.treat.chatBadgeName
        case .drink: SponsorTier.drink.chatBadgeName
        case .feast: SponsorTier.feast.chatBadgeName
        }
    }

    var usesCircle: Bool { self != .droplet }
}

struct SponsorStatistics: Equatable, Sendable {
    private(set) var counts: [SponsorTier: Int] = [:]

    var total: Int {
        counts.values.reduce(0, +)
    }

    subscript(_ tier: SponsorTier) -> Int {
        counts[tier, default: 0]
    }

    mutating func add(_ quantity: Int, for tier: SponsorTier) {
        counts[tier, default: 0] += max(quantity, 1)
    }
}

struct SponsorCelebration: Identifiable, Equatable, Sendable {
    let id = UUID()
    let tier: SponsorTier
}

extension Notification.Name {
    static let sponsorEasterEggDidChange = Notification.Name(
        "com.uuzsama450.mocca.sponsorEasterEggDidChange"
    )
}

enum SponsorAvatarWearer: String, Sendable {
    case none
    case assistant
    case user
}

struct SponsorEasterEggBackupState: Codable, Hashable, Sendable {
    var pendingTiers: [String]
    var armedConversationID: UUID?
    var armedTier: String?
    var discoveredTiers: [String]
    var selectedTier: String?
    var selectedWardrobeItem: String?
    var wearer: String?
}

/// Keeps the sponsor easter egg outside conversation persistence. A completed
/// purchase unlocks its wardrobe item and queues one temporary badge for the
/// next explicit New Chat action. Tapping that empty-chat avatar drops and
/// consumes the temporary badge.
@MainActor
enum SponsorEasterEggPersistence {
    private static let pendingTiersKey = "sponsor.easterEgg.pendingTiers.v1"
    private static let armedConversationIDKey = "sponsor.easterEgg.armedConversationID.v1"
    private static let armedTierKey = "sponsor.easterEgg.armedTier.v1"
    private static let discoveredTiersKey = "sponsor.easterEgg.discoveredTiers.v1"
    private static let selectedTierKey = "sponsor.easterEgg.selectedTier.v1"
    private static let selectedWardrobeItemKey = "sponsor.easterEgg.selectedItem.v2"
    private static let wearerKey = "sponsor.easterEgg.wearer.v1"
    private static let maximumPendingBadges = 24

    static func enqueue(_ tier: SponsorTier) {
        var pending = UserDefaults.standard.stringArray(forKey: pendingTiersKey) ?? []
        pending.append(tier.rawValue)
        if pending.count > maximumPendingBadges {
            pending.removeFirst(pending.count - maximumPendingBadges)
        }
        UserDefaults.standard.set(pending, forKey: pendingTiersKey)
        unlock([tier])
    }

    @discardableResult
    static func armNextNewChat(for conversationID: UUID) -> SponsorTier? {
        if let armedTier = storedTier(forKey: armedTierKey) {
            UserDefaults.standard.set(
                conversationID.uuidString,
                forKey: armedConversationIDKey
            )
            notifyChange()
            return armedTier
        }

        var pending = UserDefaults.standard.stringArray(forKey: pendingTiersKey) ?? []
        while !pending.isEmpty {
            let rawValue = pending.removeFirst()
            guard let tier = SponsorTier(rawValue: rawValue) else { continue }

            UserDefaults.standard.set(pending, forKey: pendingTiersKey)
            UserDefaults.standard.set(
                conversationID.uuidString,
                forKey: armedConversationIDKey
            )
            UserDefaults.standard.set(tier.rawValue, forKey: armedTierKey)
            notifyChange()
            return tier
        }

        UserDefaults.standard.set(pending, forKey: pendingTiersKey)
        return nil
    }

    static func armedTier(for conversationID: UUID) -> SponsorTier? {
        guard UserDefaults.standard.string(forKey: armedConversationIDKey)
                == conversationID.uuidString,
              let tier = storedTier(forKey: armedTierKey) else {
            return nil
        }
        return tier
    }

    @discardableResult
    static func consumeArmedEgg(for conversationID: UUID) -> SponsorTier? {
        guard let tier = armedTier(for: conversationID) else { return nil }

        UserDefaults.standard.removeObject(forKey: armedConversationIDKey)
        UserDefaults.standard.removeObject(forKey: armedTierKey)
        notifyChange()
        return tier
    }

    static var unlockedTiers: [SponsorTier] {
        let rawValues = Set(
            UserDefaults.standard.stringArray(forKey: discoveredTiersKey) ?? []
        )
        return SponsorTier.allCases.filter { rawValues.contains($0.rawValue) }
    }

    static var selectedTier: SponsorTier? {
        guard let tier = storedTier(forKey: selectedTierKey),
              unlockedTiers.contains(tier) else { return nil }
        return tier
    }

    static var unlockedWardrobeItems: [SponsorWardrobeItem] {
        let tiers = unlockedTiers
        guard !tiers.isEmpty else { return [] }
        return [.droplet] + tiers.map(SponsorWardrobeItem.init(tier:))
    }

    static var selectedWardrobeItem: SponsorWardrobeItem? {
        if let rawValue = UserDefaults.standard.string(forKey: selectedWardrobeItemKey),
           let item = SponsorWardrobeItem(rawValue: rawValue),
           unlockedWardrobeItems.contains(item) {
            return item
        }
        if let selectedTier {
            return SponsorWardrobeItem(tier: selectedTier)
        }
        return unlockedWardrobeItems.first
    }

    static var wearer: SponsorAvatarWearer {
        guard let rawValue = UserDefaults.standard.string(forKey: wearerKey) else {
            return .none
        }
        return SponsorAvatarWearer(rawValue: rawValue) ?? .none
    }

    static func select(_ tier: SponsorTier) {
        guard unlockedTiers.contains(tier) else { return }
        UserDefaults.standard.set(tier.rawValue, forKey: selectedTierKey)
        UserDefaults.standard.set(
            SponsorWardrobeItem(tier: tier).rawValue,
            forKey: selectedWardrobeItemKey
        )
        notifyChange()
    }

    static func select(_ item: SponsorWardrobeItem) {
        guard unlockedWardrobeItems.contains(item) else { return }
        UserDefaults.standard.set(item.rawValue, forKey: selectedWardrobeItemKey)
        if let tier = item.tier {
            UserDefaults.standard.set(tier.rawValue, forKey: selectedTierKey)
        }
        notifyChange()
    }

    static func restoreUnlockedTiers(_ tiers: Set<SponsorTier>) {
        unlock(tiers)
    }

    static func setWearer(_ wearer: SponsorAvatarWearer) {
        UserDefaults.standard.set(wearer.rawValue, forKey: wearerKey)
        notifyChange()
    }

    static func backupState() -> SponsorEasterEggBackupState {
        SponsorEasterEggBackupState(
            pendingTiers: UserDefaults.standard.stringArray(forKey: pendingTiersKey) ?? [],
            armedConversationID: UserDefaults.standard.string(forKey: armedConversationIDKey)
                .flatMap(UUID.init(uuidString:)),
            armedTier: UserDefaults.standard.string(forKey: armedTierKey),
            discoveredTiers: UserDefaults.standard.stringArray(forKey: discoveredTiersKey) ?? [],
            selectedTier: UserDefaults.standard.string(forKey: selectedTierKey),
            selectedWardrobeItem: UserDefaults.standard.string(forKey: selectedWardrobeItemKey),
            wearer: UserDefaults.standard.string(forKey: wearerKey)
        )
    }

    static func restoreBackupState(
        _ state: SponsorEasterEggBackupState,
        merge: Bool
    ) {
        let validTiers = Set(SponsorTier.allCases.map(\.rawValue))
        let incomingPending = state.pendingTiers.filter { validTiers.contains($0) }
        let incomingDiscovered = Set(state.discoveredTiers.filter { validTiers.contains($0) })

        if merge {
            var pending = UserDefaults.standard.stringArray(forKey: pendingTiersKey) ?? []
            pending.append(contentsOf: incomingPending)
            if pending.count > maximumPendingBadges {
                pending.removeFirst(pending.count - maximumPendingBadges)
            }
            UserDefaults.standard.set(pending, forKey: pendingTiersKey)

            let discovered = Set(
                UserDefaults.standard.stringArray(forKey: discoveredTiersKey) ?? []
            ).union(incomingDiscovered)
            UserDefaults.standard.set(discovered.sorted(), forKey: discoveredTiersKey)

            if UserDefaults.standard.string(forKey: selectedTierKey) == nil,
               let selectedTier = state.selectedTier,
               validTiers.contains(selectedTier) {
                UserDefaults.standard.set(selectedTier, forKey: selectedTierKey)
            }
            if UserDefaults.standard.string(forKey: selectedWardrobeItemKey) == nil,
               let item = state.selectedWardrobeItem,
               SponsorWardrobeItem(rawValue: item) != nil {
                UserDefaults.standard.set(item, forKey: selectedWardrobeItemKey)
            }
            if wearer == .none,
               let incomingWearer = state.wearer,
               SponsorAvatarWearer(rawValue: incomingWearer) != nil {
                UserDefaults.standard.set(incomingWearer, forKey: wearerKey)
            }
            if UserDefaults.standard.string(forKey: armedTierKey) == nil,
               let armedTier = state.armedTier,
               validTiers.contains(armedTier),
               let conversationID = state.armedConversationID {
                UserDefaults.standard.set(armedTier, forKey: armedTierKey)
                UserDefaults.standard.set(conversationID.uuidString, forKey: armedConversationIDKey)
            }
        } else {
            UserDefaults.standard.set(
                Array(incomingPending.suffix(maximumPendingBadges)),
                forKey: pendingTiersKey
            )
            UserDefaults.standard.set(incomingDiscovered.sorted(), forKey: discoveredTiersKey)
            setOrRemove(state.selectedTier.flatMap {
                validTiers.contains($0) ? $0 : nil
            }, forKey: selectedTierKey)
            setOrRemove(state.selectedWardrobeItem.flatMap {
                SponsorWardrobeItem(rawValue: $0) == nil ? nil : $0
            }, forKey: selectedWardrobeItemKey)
            setOrRemove(state.wearer.flatMap {
                SponsorAvatarWearer(rawValue: $0) == nil ? nil : $0
            }, forKey: wearerKey)
            if let armedTier = state.armedTier,
               validTiers.contains(armedTier),
               let conversationID = state.armedConversationID {
                UserDefaults.standard.set(armedTier, forKey: armedTierKey)
                UserDefaults.standard.set(conversationID.uuidString, forKey: armedConversationIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: armedTierKey)
                UserDefaults.standard.removeObject(forKey: armedConversationIDKey)
            }
        }
        notifyChange()
    }

    static func wornTier(for target: SponsorAvatarWearer) -> SponsorTier? {
        guard target != .none, wearer == target else { return nil }
        return selectedTier
    }

    static func wornWardrobeItem(
        for target: SponsorAvatarWearer
    ) -> SponsorWardrobeItem? {
        guard target != .none, wearer == target else { return nil }
        return selectedWardrobeItem
    }

    private static func storedTier(forKey key: String) -> SponsorTier? {
        guard let rawValue = UserDefaults.standard.string(forKey: key) else {
            return nil
        }
        return SponsorTier(rawValue: rawValue)
    }

    private static func setOrRemove(_ value: String?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func unlock<S: Sequence>(_ tiers: S) where S.Element == SponsorTier {
        var unlocked = Set(
            UserDefaults.standard.stringArray(forKey: discoveredTiersKey) ?? []
        )
        let previous = unlocked
        for tier in tiers {
            unlocked.insert(tier.rawValue)
        }
        guard unlocked != previous else { return }

        UserDefaults.standard.set(unlocked.sorted(), forKey: discoveredTiersKey)
        if selectedTier == nil,
           let first = SponsorTier.allCases.first(where: { unlocked.contains($0.rawValue) }) {
            UserDefaults.standard.set(first.rawValue, forKey: selectedTierKey)
        }
        notifyChange()
    }

    private static func notifyChange() {
        NotificationCenter.default.post(name: .sponsorEasterEggDidChange, object: nil)
    }
}

@MainActor
@Observable
final class SponsorStore {
    static let shared = SponsorStore()
    private static let productLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.uuzsama450.mocca",
        category: "SponsorProducts"
    )

    private(set) var productsByID: [String: Product] = [:]
    private(set) var statistics = SponsorStatistics()
    private(set) var isLoadingProducts = false
    private var productLoadingErrorKey: String?
    var productLoadingMessage: String? {
        productLoadingErrorKey.map { L10n.lookup($0) }
    }
    var hasMissingProducts: Bool {
        !SponsorTier.productIDs.isSubset(of: Set(productsByID.keys))
    }
    private(set) var purchasingTier: SponsorTier?
    private(set) var isRestoringPurchases = false
    private var statusKey: String?
    private var statusArguments: [String] = []
    var statusMessage: String? {
        statusKey.map { L10n.format($0, statusArguments) }
    }
    private(set) var statusIsError = false
    private(set) var celebration: SponsorCelebration?

    private var isPrepared = false
    @ObservationIgnored private var productLoadingTask: Task<Void, Never>?
    private var handledTransactionIDs = Set<UInt64>()

    func product(for tier: SponsorTier) -> Product? {
        productsByID[tier.productID]
    }

    func prepare() async {
        guard AppBuildConfiguration.sponsorshipEnabled else { return }
        // A failed or incomplete request must not be cached for the app's lifetime.
        if hasMissingProducts {
            await loadProducts()
        }
        guard !Task.isCancelled, !isPrepared else { return }
        isPrepared = true
        await refreshStatistics()
    }

    func retryLoadingProducts() async {
        guard AppBuildConfiguration.sponsorshipEnabled else { return }
        await loadProducts()
    }

    func listenForTransactions() async {
        guard AppBuildConfiguration.sponsorshipEnabled else { return }
        for await verification in StoreKit.Transaction.updates {
            guard case .verified(let transaction) = verification,
                  SponsorTier.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  let tier = SponsorTier.allCases.first(where: {
                      $0.productID == transaction.productID
                  }) else { continue }
            await complete(transaction, tier: tier)
        }
    }

    func purchase(_ tier: SponsorTier) async {
        guard AppBuildConfiguration.sponsorshipEnabled else { return }
        guard purchasingTier == nil, !isRestoringPurchases else { return }
        guard let product = product(for: tier) else {
            setStatus("这个投喂项目暂时没有载入，请稍后重试。", isError: true)
            return
        }

        purchasingTier = tier
        statusKey = nil
        statusIsError = false
        defer { purchasingTier = nil }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    setStatus("App Store 没有通过这笔交易的验证，没有计入投喂。", isError: true)
                    return
                }
                await complete(transaction, tier: tier)
            case .pending:
                setStatus("这次投喂正在等待 App Store 确认。确认完成后会自动更新。")
            case .userCancelled:
                break
            @unknown default:
                setStatus("暂时无法完成投喂，请稍后再试。", isError: true)
            }
        } catch {
            setStatus("暂时无法连接 App Store，请稍后再试。", isError: true)
        }
    }

    func restorePurchases() async {
        guard AppBuildConfiguration.sponsorshipEnabled else { return }
        guard purchasingTier == nil, !isRestoringPurchases else { return }

        isRestoringPurchases = true
        setStatus("正在向 App Store 查找以前的投喂记录…")
        statusIsError = false
        defer { isRestoringPurchases = false }

        do {
            try await AppStore.sync()
            await refreshStatistics()
            if statistics.total > 0 {
                setStatus("已经找回 %@ 次投喂记录，买过档位的永久纪念装扮已放回衣柜。", arguments: [String(statistics.total)])
            } else {
                setStatus("这个 Apple Account 暂时没有可恢复的投喂记录。")
            }
        } catch {
            setStatus("暂时无法向 App Store 恢复购买，请稍后再试。", isError: true)
        }
    }

    private func loadProducts() async {
        if let productLoadingTask {
            await productLoadingTask.value
            return
        }

        isLoadingProducts = true
        productLoadingErrorKey = nil
        // The store owns the request so leaving the page cannot cancel a request
        // that a newly opened page is still waiting for. All callers share it.
        let task = Task { @MainActor in
            defer {
                self.isLoadingProducts = false
                self.productLoadingTask = nil
            }
            await self.fetchProducts()
        }
        productLoadingTask = task
        await task.value
    }

    private func fetchProducts() async {
        let requestedIDs = SponsorTier.productIDs
        Self.productLogger.notice("Requesting products: bundle=\(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public) ids=\(requestedIDs.sorted().joined(separator: ","), privacy: .public)")
        do {
            let products = try await Product.products(for: requestedIDs)
            productsByID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
            let missingIDs = requestedIDs.subtracting(productsByID.keys)
            Self.productLogger.notice("Products received: ids=\(products.map(\.id).sorted().joined(separator: ","), privacy: .public) missing=\(missingIDs.sorted().joined(separator: ","), privacy: .public)")
            if products.isEmpty {
                productLoadingErrorKey = "投喂项目还没有从 App Store 载入。"
            } else if !missingIDs.isEmpty {
                productLoadingErrorKey = "部分投喂项目暂时没有载入，请重新载入。"
            }
        } catch {
            // Keep any products already loaded when a retry has a transient error.
            // Product loading must not replace purchase/restore status messages.
            productLoadingErrorKey = "投喂项目暂时无法载入，请稍后重试。"
            let failure = error as NSError
            let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            Self.productLogger.error("Product request failed: domain=\(failure.domain, privacy: .public) code=\(failure.code) underlyingDomain=\(underlying?.domain ?? "none", privacy: .public) underlyingCode=\(underlying?.code ?? 0)")
        }
    }

    private func refreshStatistics() async {
        var refreshed = SponsorStatistics()
        var seenTransactionIDs = Set<UInt64>()
        var purchasedTiers = Set<SponsorTier>()

        for await verification in StoreKit.Transaction.all {
            guard case .verified(let transaction) = verification,
                  transaction.revocationDate == nil,
                  seenTransactionIDs.insert(transaction.id).inserted,
                  let tier = SponsorTier.allCases.first(where: {
                      $0.productID == transaction.productID
                  }) else { continue }
            refreshed.add(transaction.purchasedQuantity, for: tier)
            purchasedTiers.insert(tier)
        }

        statistics = refreshed
        SponsorEasterEggPersistence.restoreUnlockedTiers(purchasedTiers)
    }

    private func complete(_ transaction: StoreKit.Transaction, tier: SponsorTier) async {
        let shouldCelebrate = handledTransactionIDs.insert(transaction.id).inserted
        await transaction.finish()
        await refreshStatistics()

        guard shouldCelebrate else { return }
        SponsorEasterEggPersistence.enqueue(tier)
        setStatus(tier.thankYou)
        let event = SponsorCelebration(tier: tier)
        celebration = event
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard self?.celebration?.id == event.id else { return }
            self?.celebration = nil
        }
    }

    private func setStatus(_ message: String, arguments: [String] = [], isError: Bool = false) {
        statusKey = message
        statusArguments = arguments
        statusIsError = isError
    }
}
