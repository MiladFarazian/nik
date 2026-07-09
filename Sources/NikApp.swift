import SwiftUI

@main
struct NikApp: App {
    @State private var templateStore = TemplateStore()
    @State private var projectStore = ProjectStore()
    @State private var photoLibrary = PhotoLibrary()
    @State private var personalization = PersonalizationStore()
    @State private var deepLinks = DeepLinkRouter()
    @State private var storeService: StoreService
    @State private var entitlements: Entitlements

    init() {
        let store = StoreService()
        _storeService = State(initialValue: store)
        _entitlements = State(initialValue: Entitlements(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .task { await templateStore.refresh() }
                .environment(templateStore)
                .environment(projectStore)
                .environment(photoLibrary)
                .environment(personalization)
                .environment(deepLinks)
                .environment(storeService)
                .environment(entitlements)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

/// Pro entitlement state. Backed by real StoreKit 2 purchases via `StoreService`;
/// `isPro` stays the stable interface the rest of the app reads (ExportView,
/// TemplatePagerView) so nothing downstream needs to know about StoreKit.
@MainActor
@Observable
final class Entitlements {
    private let store: StoreService

    #if DEBUG
    /// Manual override for simulator/testing, since StoreKit sandbox purchases
    /// aren't always convenient to exercise. Never compiled into release builds.
    var debugForcePro: Bool = UserDefaults.standard.bool(forKey: "nik.debugForcePro") {
        didSet { UserDefaults.standard.set(debugForcePro, forKey: "nik.debugForcePro") }
    }
    #endif

    init(store: StoreService) {
        self.store = store
    }

    var isPro: Bool {
        #if DEBUG
        if debugForcePro { return true }
        #endif
        return store.isPro
    }
}
