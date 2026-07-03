import SwiftUI

struct ProfileView: View {
    @Environment(Entitlements.self) private var entitlements
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if entitlements.isPro {
                        Label("nik Pro — active", systemImage: "crown.fill")
                            .foregroundStyle(Theme.proBadge)
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
                    Toggle("Pro entitlement", isOn: Binding(
                        get: { entitlements.isPro },
                        set: { entitlements.isPro = $0 }
                    ))
                }
                #endif
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Profile")
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
    }
}

/// Contextual paywall sheet. StoreKit 2 products plug in behind the buttons;
/// the DEBUG toggle in Profile simulates the entitlement meanwhile.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Entitlements.self) private var entitlements

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

            VStack(spacing: 10) {
                Button {
                    // StoreKit purchase goes here.
                    entitlements.isPro = true
                    Haptics.success()
                    dismiss()
                } label: {
                    VStack(spacing: 2) {
                        Text("Try free for 7 days")
                            .font(.system(size: 17, weight: .semibold))
                        Text("then $39.99/year — cancel anytime")
                            .font(.system(size: 12))
                            .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 14))
                }

                Button("Restore purchases") {}
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface1)
        .preferredColorScheme(.dark)
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
