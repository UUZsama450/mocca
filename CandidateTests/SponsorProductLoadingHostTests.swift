import Foundation
import StoreKit

// This host module intentionally shadows StoreKit.Product. SponsorStore itself
// is compiled in full; only external product/history I/O is deterministic here.
// These checks do not validate StoreKit, App Store Connect, prices, or purchases.
struct Product: Sendable {
    let id: String

    @MainActor
    static func products<Identifiers: Collection>(
        for identifiers: Identifiers
    ) async throws -> [Product] where Identifiers.Element == String {
        try await SponsorHostIO.request(Set(identifiers))
    }

    func purchase() async throws -> StoreKit.Product.PurchaseResult {
        throw SponsorHostFailure.unexpectedPurchase
    }
}

enum SponsorHostFailure: Error {
    case offline
    case unexpectedPurchase
}

@MainActor
enum L10n {
    static func lookup(_ key: String) -> String { key }

    static func format(_ key: String, _ arguments: [String]) -> String {
        String(format: key, arguments: arguments.map { $0 as CVarArg })
    }
}

@MainActor
enum SponsorHostIO {
    static var requestedIDs: [Set<String>] = []
    static var requestWasCancelled: [Bool] = []
    static var completedRequestWasCancelled: [Bool] = []
    static var pending: [CheckedContinuation<[Product], any Error>] = []
    static var historyReads = 0
    static var callersEntered = 0

    static var emptyTransactionHistory: AsyncStream<VerificationResult<StoreKit.Transaction>> {
        historyReads += 1
        return AsyncStream { $0.finish() }
    }

    static func reset() {
        require(pending.isEmpty, "The prior scenario left an unfinished request")
        requestedIDs = []
        requestWasCancelled = []
        completedRequestWasCancelled = []
        historyReads = 0
        callersEntered = 0
    }

    static func request(_ ids: Set<String>) async throws -> [Product] {
        requestedIDs.append(ids)
        requestWasCancelled.append(Task.isCancelled)
        defer { completedRequestWasCancelled.append(Task.isCancelled) }
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    static func succeed(_ tiers: [SponsorTier] = SponsorTier.allCases) {
        require(pending.count == 1, "Expected exactly one active product request")
        pending.removeFirst().resume(returning: tiers.map { Product(id: $0.productID) })
    }

    static func fail(_ error: any Error = SponsorHostFailure.offline) {
        require(pending.count == 1, "Expected exactly one active product request")
        pending.removeFirst().resume(throwing: error)
    }

    static func waitUntil(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        fatalError("Timed out: \(message)")
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}

@main
struct SponsorProductLoadingHostTests {
    @MainActor
    static func main() async {
        await failureThenReentry()
        await emptyThenReentry()
        await partialThenRetry()
        await concurrentCallsShareRequest()
        await cancelledPageDoesNotCancelSharedLoad()
        await cancelledRequestCanRetry()
        await productRefreshPreservesPurchaseStatus()
        print("SPONSOR_PRODUCT_LOADING_HOST_TESTS=PASS (7 scenarios)")
    }

    @MainActor
    static func failureThenReentry() async {
        SponsorHostIO.reset()
        let store = SponsorStore()
        let first = Task { await store.prepare() }
        await SponsorHostIO.waitUntil("first request") { SponsorHostIO.pending.count == 1 }
        SponsorHostIO.require(store.isLoadingProducts, "Loading indicator should cover pending I/O")
        SponsorHostIO.fail()
        await first.value
        SponsorHostIO.require(!store.isLoadingProducts, "Failure should finish loading")
        SponsorHostIO.require(store.hasMissingProducts, "Failure should leave a retry path")
        SponsorHostIO.require(store.productLoadingMessage != nil, "Failure should explain why products are missing")

        let second = Task { await store.prepare() }
        await SponsorHostIO.waitUntil("reentry after failure") { SponsorHostIO.pending.count == 1 }
        SponsorHostIO.require(SponsorHostIO.requestedIDs.count == 2, "Reentry must retry a failed first load")
        SponsorHostIO.succeed()
        await second.value
        SponsorHostIO.require(!store.hasMissingProducts, "All products should complete the catalog")
        SponsorHostIO.require(store.productLoadingMessage == nil, "Success should clear the loading error")
        await store.prepare()
        SponsorHostIO.require(SponsorHostIO.requestedIDs.count == 2, "A complete catalog should not reload on every entry")
        SponsorHostIO.require(SponsorHostIO.historyReads == 1, "Normal reentry should not rescan transaction history")
        SponsorHostIO.require(SponsorHostIO.requestedIDs.allSatisfy { $0 == SponsorTier.productIDs }, "Requests should include all configured product IDs")
        print("PASS failed load -> reentry -> recovery; successful entry remains cached")
    }

    @MainActor
    static func emptyThenReentry() async {
        SponsorHostIO.reset()
        let store = SponsorStore()
        let first = Task { await store.prepare() }
        await SponsorHostIO.waitUntil("empty response request") { SponsorHostIO.pending.count == 1 }
        SponsorHostIO.succeed([])
        await first.value
        SponsorHostIO.require(store.hasMissingProducts && store.productLoadingMessage != nil, "Empty success must expose recovery")
        let second = Task { await store.prepare() }
        await SponsorHostIO.waitUntil("reentry after empty response") { SponsorHostIO.pending.count == 1 }
        SponsorHostIO.succeed()
        await second.value
        SponsorHostIO.require(!store.hasMissingProducts && !store.isLoadingProducts, "Empty response must not permanently prepare the catalog")
        print("PASS empty response -> reentry -> recovery")
    }

    @MainActor
    static func partialThenRetry() async {
        SponsorHostIO.reset()
        let store = SponsorStore()
        let first = Task { await store.prepare() }
        await SponsorHostIO.waitUntil("partial response request") { SponsorHostIO.pending.count == 1 }
        SponsorHostIO.succeed([.treat])
        await first.value
        SponsorHostIO.require(store.product(for: .treat) != nil, "A loaded product should remain available")
        SponsorHostIO.require(store.product(for: .drink) == nil && store.product(for: .feast) == nil, "Missing tiers must stay unavailable")
        SponsorHostIO.require(store.hasMissingProducts && store.productLoadingMessage != nil, "Partial success must offer retry with an explanation")

        let retry = Task { await store.retryLoadingProducts() }
        await SponsorHostIO.waitUntil("retry partial response") { SponsorHostIO.pending.count == 1 }
        SponsorHostIO.require(store.product(for: .treat) != nil, "Loading should not discard already available products")
        SponsorHostIO.fail()
        await retry.value
        SponsorHostIO.require(store.product(for: .treat) != nil && store.hasMissingProducts, "A transient retry failure must preserve prior partial products")

        let reentry = Task { await store.prepare() }
        await SponsorHostIO.waitUntil("partial reentry") { SponsorHostIO.pending.count == 1 }
        SponsorHostIO.succeed()
        await reentry.value
        SponsorHostIO.require(!store.hasMissingProducts && store.productLoadingMessage == nil, "Retry should fill all missing tiers and remove the loading error")
        print("PASS partial catalog -> failed retry preserves products -> reentry fills missing tiers")
    }

    @MainActor
    static func concurrentCallsShareRequest() async {
        SponsorHostIO.reset()
        let store = SponsorStore()
        let first = Task { await store.prepare() }
        await SponsorHostIO.waitUntil("concurrent initial request") { SponsorHostIO.pending.count == 1 }
        let joiners = (0..<6).map { index in
            Task { @MainActor in
                SponsorHostIO.callersEntered += 1
                if index.isMultiple(of: 2) {
                    await store.prepare()
                } else {
                    await store.retryLoadingProducts()
                }
            }
        }
        await SponsorHostIO.waitUntil("all concurrent callers") { SponsorHostIO.callersEntered == 6 }
        SponsorHostIO.require(SponsorHostIO.requestedIDs.count == 1, "Simultaneous prepare/retry calls should share one request")
        SponsorHostIO.require(store.isLoadingProducts, "Joining a load should not prematurely clear the loading indicator")
        SponsorHostIO.succeed()
        await first.value
        for joiner in joiners { await joiner.value }
        SponsorHostIO.require(SponsorHostIO.requestedIDs.count == 1 && !store.isLoadingProducts, "All callers must observe one completed load")
        SponsorHostIO.require(!store.hasMissingProducts, "Joined callers should receive the completed catalog")
        SponsorHostIO.require(SponsorHostIO.historyReads == 1, "Concurrent prepare should initialize history once")
        print("PASS simultaneous prepare/retry calls share one request and history initialization")
    }

    @MainActor
    static func cancelledPageDoesNotCancelSharedLoad() async {
        SponsorHostIO.reset()
        let store = SponsorStore()
        let firstPage = Task { await store.prepare() }
        await SponsorHostIO.waitUntil("cancelled page request") { SponsorHostIO.pending.count == 1 }
        firstPage.cancel()
        let nextPage = Task { @MainActor in
            SponsorHostIO.callersEntered += 1
            await store.prepare()
        }
        await SponsorHostIO.waitUntil("new page joins") { SponsorHostIO.callersEntered == 1 }
        SponsorHostIO.require(SponsorHostIO.requestedIDs.count == 1 && store.isLoadingProducts, "Leaving the page must not fork or stop the shared load")
        SponsorHostIO.succeed()
        await firstPage.value
        await nextPage.value
        SponsorHostIO.require(!store.hasMissingProducts && !store.isLoadingProducts, "An in-flight load should survive page cancellation")
        SponsorHostIO.require(SponsorHostIO.requestWasCancelled == [false], "Shared product I/O should not inherit a page cancellation")
        SponsorHostIO.require(SponsorHostIO.completedRequestWasCancelled == [false], "Shared product I/O should still be uncancelled after its initiating page is cancelled")

        SponsorHostIO.reset()
        let laterEntryStore = SponsorStore()
        let departingPage = Task { await laterEntryStore.prepare() }
        await SponsorHostIO.waitUntil("departing page request") { SponsorHostIO.pending.count == 1 }
        departingPage.cancel()
        SponsorHostIO.succeed()
        await departingPage.value
        SponsorHostIO.require(!laterEntryStore.hasMissingProducts, "A cancelled sole caller should still allow the shared catalog to finish")
        SponsorHostIO.require(SponsorHostIO.completedRequestWasCancelled == [false], "The shared task must survive even when no page is waiting")
        SponsorHostIO.require(SponsorHostIO.historyReads == 0, "Cancelled prepare must leave history initialization available for a later live caller")
        await laterEntryStore.prepare()
        SponsorHostIO.require(SponsorHostIO.historyReads == 1, "The next live entry should initialize history")
        SponsorHostIO.require(SponsorHostIO.requestedIDs.count == 1, "The next entry should reuse the completed products")
        print("PASS page cancellation preserves shared loading and defers history to a live caller")
    }

    @MainActor
    static func cancelledRequestCanRetry() async {
        SponsorHostIO.reset()
        let store = SponsorStore()
        let first = Task { await store.prepare() }
        await SponsorHostIO.waitUntil("cancelled product request") { SponsorHostIO.pending.count == 1 }
        SponsorHostIO.fail(CancellationError())
        await first.value
        SponsorHostIO.require(!store.isLoadingProducts && store.hasMissingProducts, "Cancellation must release loading state without declaring products complete")
        let second = Task { await store.prepare() }
        await SponsorHostIO.waitUntil("reentry after product cancellation") { SponsorHostIO.pending.count == 1 }
        SponsorHostIO.succeed()
        await second.value
        SponsorHostIO.require(!store.hasMissingProducts && !store.isLoadingProducts, "A cancelled load must not block the next entry")
        print("PASS product-request cancellation cleans up and permits reentry")
    }

    @MainActor
    static func productRefreshPreservesPurchaseStatus() async {
        SponsorHostIO.reset()
        let store = SponsorStore()
        let first = Task { await store.prepare() }
        await SponsorHostIO.waitUntil("status isolation initial request") { SponsorHostIO.pending.count == 1 }
        SponsorHostIO.succeed([.treat])
        await first.value
        await store.purchase(.feast)
        let purchaseMessage = store.statusMessage
        SponsorHostIO.require(purchaseMessage != nil && store.statusIsError, "Unavailable purchase should explain its failure")

        let retry = Task { await store.retryLoadingProducts() }
        await SponsorHostIO.waitUntil("status isolation retry") { SponsorHostIO.pending.count == 1 }
        SponsorHostIO.fail()
        await retry.value
        SponsorHostIO.require(store.statusMessage == purchaseMessage && store.statusIsError, "Loading errors must not overwrite the purchase result")
        SponsorHostIO.require(store.productLoadingMessage != nil, "Product errors should remain independently visible")

        let recovery = Task { await store.retryLoadingProducts() }
        await SponsorHostIO.waitUntil("status isolation recovery") { SponsorHostIO.pending.count == 1 }
        SponsorHostIO.succeed()
        await recovery.value
        SponsorHostIO.require(store.statusMessage == purchaseMessage && store.statusIsError, "Catalog success must not erase an unrelated purchase error")
        SponsorHostIO.require(store.productLoadingMessage == nil, "Catalog success should clear only its own error")
        print("PASS product loading failure/success preserves independent purchase status")
    }
}
