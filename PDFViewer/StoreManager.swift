import Foundation
import StoreKit

/// StoreKit 2 manager for the one-and-only purchase in this app:
/// **Remove Ads** — a non-consumable at $4.99 (price is set on the
/// product in App Store Connect; the code only knows the product ID).
///
/// Owning it means: the banner never loads and the timed interstitial
/// is fully disabled (AdManager checks `removeAdsOwned` before every
/// load, every timer tick, and every presentation).
@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    static let removeAdsProductID = "com.swishgame.pdfviewer.remove_ads"

    /// True when the Remove Ads entitlement is currently held.
    @Published private(set) var removeAdsOwned = false
    /// The App Store product, once loaded (carries the real price).
    @Published private(set) var product: Product?
    @Published private(set) var isPurchasing = false
    /// One-line outcome of the last purchase/restore attempt, shown in
    /// Settings so the user always gets an answer.
    @Published var lastMessage: String?

    private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = listenForTransactions()
        Task { await refresh() }
    }

    /// Loads the product and the current entitlement. Called at launch
    /// and whenever Settings appears.
    func refresh() async {
        if let loaded = try? await Product.products(for: [Self.removeAdsProductID]).first {
            product = loaded
        }
        await updateEntitlement()
    }

    /// Recomputes `removeAdsOwned` from the live entitlement set.
    func updateEntitlement() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.removeAdsProductID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        removeAdsOwned = owned
    }

    /// Runs the purchase flow for Remove Ads.
    func purchaseRemoveAds() async {
        guard let product else {
            lastMessage = "The store isn't reachable right now — please try again."
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await updateEntitlement()
                    lastMessage = removeAdsOwned
                        ? "Ads removed. Thank you!"
                        : "Purchase finished — checking your receipt…"
                } else {
                    lastMessage = "The purchase couldn't be verified."
                }
            case .userCancelled:
                lastMessage = nil
            case .pending:
                lastMessage = "Purchase is pending approval."
            @unknown default:
                lastMessage = "Something went wrong — please try again."
            }
        } catch {
            lastMessage = "The purchase didn't go through — please try again."
        }
    }

    /// Restore Purchases (App Store guideline requirement — surfaced in
    /// Settings next to the buy button).
    func restorePurchases() async {
        do {
            try await AppStore.sync()
        } catch {
            lastMessage = "Restore couldn't reach the App Store — please try again."
            return
        }
        await updateEntitlement()
        lastMessage = removeAdsOwned
            ? "Remove Ads restored. Thank you!"
            : "No previous purchase was found for this Apple ID."
    }

    /// Watches for transactions arriving outside the buy button
    /// (Ask-to-Buy approvals, purchases on another device, refunds).
    private func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) {
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await self.updateEntitlement()
            }
        }
    }
}
