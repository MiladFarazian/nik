import Foundation
import StoreKit

/// StoreKit 2 wrapper for nik Pro. Loads the two auto-renewable subscription
/// products, drives purchase/restore, and keeps `isPro` in sync by iterating
/// `Transaction.currentEntitlements` and listening for `Transaction.updates`.
///
/// `Entitlements` (see NikApp.swift) is the stable interface the rest of the
/// app reads from; this type is the StoreKit-facing implementation behind it.
@MainActor
@Observable
final class StoreService {
    static let yearlyProductID = "nik.pro.yearly"
    static let monthlyProductID = "nik.pro.monthly"
    private static let productIDs: [String] = [yearlyProductID, monthlyProductID]

    enum PurchaseOutcome {
        case success
        case pending
        case userCancelled
    }

    enum StoreError: LocalizedError {
        case failedVerification
        case productNotFound

        var errorDescription: String? {
            switch self {
            case .failedVerification:
                return "This purchase could not be verified. Please try again."
            case .productNotFound:
                return "That subscription isn't available right now."
            }
        }
    }

    /// Products sorted with the yearly plan first (the default selection).
    private(set) var products: [Product] = []
    private(set) var purchasedProductIDs: Set<String> = []
    private(set) var isPro: Bool = false
    /// Expiration/renewal date of the active entitlement, when known. Nil for
    /// lifetime or non-subscription entitlements (not used today, but cheap to keep).
    private(set) var activeExpirationDate: Date?

    var isLoadingProducts = false
    var productsError: String?
    var isPurchasing = false
    var purchaseError: String?

    @ObservationIgnored nonisolated(unsafe) private var transactionListenerTask: Task<Void, Never>?

    var yearlyProduct: Product? { products.first { $0.id == Self.yearlyProductID } }
    var monthlyProduct: Product? { products.first { $0.id == Self.monthlyProductID } }
    /// The purchased product backing the current entitlement, if any.
    var activeProduct: Product? { products.first { purchasedProductIDs.contains($0.id) } }

    init() {
        transactionListenerTask = Self.startTransactionListener(for: self)
        Task { [weak self] in
            await self?.loadProducts()
            await self?.updateEntitlements()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Products

    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoadingProducts = true
        productsError = nil
        defer { isLoadingProducts = false }
        do {
            let storeProducts = try await Product.products(for: Self.productIDs)
            products = storeProducts.sorted { lhs, _ in lhs.id == Self.yearlyProductID }
        } catch {
            productsError = error.localizedDescription
        }
    }

    // MARK: - Purchase / restore

    /// Purchases a product. Throws only for genuine failures (network,
    /// verification); `.pending` and `.userCancelled` are returned as normal
    /// outcomes so callers can present calm, non-error UI for them.
    func purchase(_ product: Product) async throws -> PurchaseOutcome {
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await updateEntitlements()
            await transaction.finish()
            return .success
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            return .pending
        }
    }

    /// Syncs with the App Store and refreshes entitlements. Errors are
    /// surfaced via `purchaseError` rather than thrown, since restore is
    /// typically triggered from a "quiet" UI affordance.
    func restore() async {
        purchaseError = nil
        do {
            try await AppStore.sync()
        } catch {
            purchaseError = error.localizedDescription
        }
        await updateEntitlements()
    }

    // MARK: - Entitlement state

    func updateEntitlements() async {
        var activeIDs: Set<String> = []
        var latestExpiration: Date?

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            guard transaction.revocationDate == nil else { continue }
            activeIDs.insert(transaction.productID)
            if let expirationDate = transaction.expirationDate {
                latestExpiration = max(latestExpiration ?? .distantPast, expirationDate)
            }
        }

        purchasedProductIDs = activeIDs
        isPro = !activeIDs.isEmpty
        activeExpirationDate = latestExpiration
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    private static func startTransactionListener(for service: StoreService) -> Task<Void, Never> {
        Task.detached { [weak service] in
            for await update in Transaction.updates {
                await service?.handle(transactionUpdate: update)
            }
        }
    }

    private func handle(transactionUpdate result: VerificationResult<Transaction>) async {
        guard let transaction = try? checkVerified(result) else { return }
        await updateEntitlements()
        await transaction.finish()
    }
}
