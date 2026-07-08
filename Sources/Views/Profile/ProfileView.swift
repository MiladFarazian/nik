import StoreKit
import SwiftUI

struct ProfileView: View {
    @Environment(Entitlements.self) private var entitlements
    @Environment(StoreService.self) private var store
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if entitlements.isPro {
                        activeProStatus
                    } else {
                        Button {
                            showPaywall = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Go Pro")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text("No watermark · 4K export · Pro templates")
                                        .font(.footnote)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .padding(.vertical, 6)
                        }
                        .listRowBackground(
                            Theme.accentGradient
                        )
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    Link(destination: URL(string: "https://example.com/terms")!) {
                        Text("Terms of Service")
                    }
                    Link(destination: URL(string: "https://example.com/privacy")!) {
                        Text("Privacy Policy")
                    }
                }

                #if DEBUG
                Section("Debug") {
                    Toggle("Force Pro entitlement", isOn: Binding(
                        get: { entitlements.debugForcePro },
                        set: { entitlements.debugForcePro = $0 }
                    ))
                    if store.isPro {
                        Text("Real StoreKit entitlement: active")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                #endif
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Profile")
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
    }

    /// Live subscription state: which product backs the entitlement, and
    /// (when known) its renewal date. Falls back to a plain "active" label
    /// when the real product isn't resolved yet (e.g. DEBUG override).
    @ViewBuilder
    private var activeProStatus: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("nik Pro — active", systemImage: "crown.fill")
                .foregroundStyle(Theme.proBadge)
            if let product = store.activeProduct {
                Text(subtitle(for: product))
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func subtitle(for product: Product) -> String {
        let name = product.id == StoreService.yearlyProductID ? "Yearly" : "Monthly"
        if let expiration = store.activeExpirationDate {
            let formatted = expiration.formatted(date: .abbreviated, time: .omitted)
            return "\(name) plan · renews \(formatted)"
        }
        return "\(name) plan"
    }
}

/// Contextual paywall sheet. Product-driven pricing via StoreKit 2, with an
/// always-visible dismiss control and no countdown/urgency dark patterns —
/// see PLAN.md §1 on the transparent-copy stance.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(StoreService.self) private var store

    @State private var selectedProductID = StoreService.yearlyProductID
    @State private var isRestoring = false
    @State private var restoreMessage: String?

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.1), in: Circle())
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)

            Image(systemName: "crown.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.proBadge)

            Text("nik Pro")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 12) {
                benefit("No watermark on exports")
                benefit("4K · 60fps export")
                benefit("All Pro templates")
                benefit("Premium caption styles")
            }

            Spacer()

            planPicker

            if let error = store.purchaseError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if let restoreMessage {
                Text(restoreMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            VStack(spacing: 10) {
                purchaseButton

                Button("Restore purchases") {
                    Task { await restore() }
                }
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .disabled(isRestoring || store.isPurchasing)
                .opacity(isRestoring ? 0.5 : 1)
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface1)
        .preferredColorScheme(.dark)
        .task {
            if store.products.isEmpty {
                await store.loadProducts()
            }
        }
    }

    // MARK: - Plan picker

    private var selectedProduct: Product? {
        store.products.first { $0.id == selectedProductID } ?? store.yearlyProduct
    }

    @ViewBuilder
    private var planPicker: some View {
        VStack(spacing: 10) {
            planRow(
                productID: StoreService.yearlyProductID,
                product: store.yearlyProduct,
                title: "Yearly",
                placeholderPrice: "$39.99/year",
                detail: yearlyDetail
            )
            planRow(
                productID: StoreService.monthlyProductID,
                product: store.monthlyProduct,
                title: "Monthly",
                placeholderPrice: "$5.99/month",
                detail: store.monthlyProduct.map { "\($0.displayPrice)/month" } ?? "$5.99/month"
            )
        }
        .padding(.horizontal)
    }

    /// True while products haven't loaded yet, or the yearly product's real
    /// StoreKit config includes a free-trial introductory offer. Placeholder
    /// copy assumes a trial (matching Nik.storekit) until the real product loads.
    private var hasYearlyTrial: Bool {
        guard let product = store.yearlyProduct else { return true }
        return product.subscription?.introductoryOffer?.paymentMode == .freeTrial
    }

    private var yearlyDetail: String {
        guard let product = store.yearlyProduct else {
            return "7 days free, then $39.99/year"
        }
        if let introOffer = product.subscription?.introductoryOffer, introOffer.paymentMode == .freeTrial {
            return "\(formattedPeriod(introOffer.period)) free, then \(product.displayPrice)/year"
        }
        return "\(product.displayPrice)/year"
    }

    private func formattedPeriod(_ period: Product.SubscriptionPeriod) -> String {
        switch period.unit {
        case .day: return period.value == 1 ? "1 day" : "\(period.value) days"
        case .week: return period.value == 1 ? "1 week" : "\(period.value) weeks"
        case .month: return period.value == 1 ? "1 month" : "\(period.value) months"
        case .year: return period.value == 1 ? "1 year" : "\(period.value) years"
        @unknown default: return "\(period.value)"
        }
    }

    private func planRow(productID: String, product: Product?, title: String, placeholderPrice: String, detail: String) -> some View {
        let isSelected = selectedProductID == productID
        return Button {
            selectedProductID = productID
            Haptics.selection()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(store.isLoadingProducts && product == nil ? placeholderPrice : detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.accent : .white.opacity(0.3))
            }
            .padding(14)
            .background(
                isSelected ? Theme.surface2 : Theme.surface1,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Theme.accent : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Purchase

    @ViewBuilder
    private var purchaseButton: some View {
        Button {
            Task { await purchase() }
        } label: {
            VStack(spacing: 2) {
                if store.isPurchasing || store.isLoadingProducts {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(purchaseButtonTitle)
                        .font(.system(size: 17, weight: .semibold))
                    Text(subtitleForSelectedPlan)
                        .font(.system(size: 12))
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 14))
            .opacity(store.isPurchasing || store.isLoadingProducts ? 0.7 : 1)
        }
        .disabled(store.isPurchasing || store.isLoadingProducts)
    }

    private var purchaseButtonTitle: String {
        if selectedProductID == StoreService.yearlyProductID {
            return hasYearlyTrial ? "Try free for \(formattedPeriodShort)" : "Subscribe yearly"
        }
        return "Subscribe monthly"
    }

    /// Short form of the yearly trial length for the button title, e.g. "7 days".
    private var formattedPeriodShort: String {
        guard let period = store.yearlyProduct?.subscription?.introductoryOffer?.period else {
            return "7 days"
        }
        return formattedPeriod(period)
    }

    private var subtitleForSelectedPlan: String {
        if selectedProductID == StoreService.yearlyProductID {
            return "\(yearlyDetail) — cancel anytime"
        } else if let monthly = store.monthlyProduct {
            return "\(monthly.displayPrice)/month — cancel anytime"
        } else {
            return "$5.99/month — cancel anytime"
        }
    }

    private func purchase() async {
        guard let product = selectedProduct else {
            // Products haven't loaded (offline / StoreKit unavailable). Retry the load
            // and, if it still fails, tell the user instead of silently no-op'ing.
            restoreMessage = nil
            store.purchaseError = nil
            await store.loadProducts()
            if selectedProduct == nil {
                store.purchaseError = store.productsError
                    ?? "Couldn't reach the App Store. Check your connection and try again."
            } else {
                await purchase()   // products arrived — proceed
            }
            return
        }
        do {
            let outcome = try await store.purchase(product)
            switch outcome {
            case .success:
                Haptics.success()
                dismiss()
            case .pending:
                restoreMessage = "Your purchase is awaiting approval. We'll unlock Pro as soon as it's confirmed."
            case .userCancelled:
                break
            }
        } catch {
            store.purchaseError = error.localizedDescription
        }
    }

    private func restore() async {
        isRestoring = true
        restoreMessage = nil
        await store.restore()
        isRestoring = false
        if store.isPro {
            Haptics.success()
            dismiss()
        } else if store.purchaseError == nil {
            restoreMessage = "No active purchases found for this Apple ID."
        }
    }

    private func benefit(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
            Text(text)
                .foregroundStyle(.white)
        }
        .font(.system(size: 15, weight: .medium))
    }
}
