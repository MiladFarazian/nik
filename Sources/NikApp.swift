import SwiftUI

@main
struct NikApp: App {
    @State private var templateStore = TemplateStore()
    @State private var projectStore = ProjectStore()
    @State private var photoLibrary = PhotoLibrary()
    @State private var entitlements = Entitlements()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(templateStore)
                .environment(projectStore)
                .environment(photoLibrary)
                .environment(entitlements)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

/// Pro entitlement state. StoreKit 2 wiring lands behind this same interface;
/// v1 keeps it as a local toggle so the paywall UX is testable end-to-end.
@Observable
final class Entitlements {
    var isPro: Bool = UserDefaults.standard.bool(forKey: "nik.isPro") {
        didSet { UserDefaults.standard.set(isPro, forKey: "nik.isPro") }
    }
}
