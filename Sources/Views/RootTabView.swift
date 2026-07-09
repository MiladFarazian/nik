import SwiftUI

enum AppTab: Hashable {
    case templates, projects, profile
}

/// Route value pushed when the user commits to a template.
struct ClipFillRoute: Hashable {
    let template: Template
}

/// Route pushed when a project is ready to edit.
struct EditorRoute: Hashable {
    let projectID: UUID
}

/// Routes nik://template/<id> deep links: RootTabView catches the URL and
/// switches tabs; TemplateFeedView watches pendingTemplateID and opens the pager.
@MainActor
@Observable
final class DeepLinkRouter {
    var pendingTemplateID: String?

    /// Parses nik://template/<id>.
    func handle(_ url: URL) {
        guard url.scheme == "nik", url.host == "template" else { return }
        let id = url.lastPathComponent
        guard !id.isEmpty, id != "/" else { return }
        pendingTemplateID = id
    }
}

struct RootTabView: View {
    @Environment(PersonalizationStore.self) private var personalization
    @Environment(DeepLinkRouter.self) private var deepLinks
    @State private var selectedTab: AppTab = .templates

    var body: some View {
        TabView(selection: $selectedTab) {
            TemplateFeedView()
                .tabItem { Label("Templates", systemImage: "square.grid.2x2.fill") }
                .tag(AppTab.templates)

            ProjectsView()
                .tabItem { Label("Projects", systemImage: "folder.fill") }
                .tag(AppTab.projects)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.fill") }
                .tag(AppTab.profile)
        }
        .background(Theme.background)
        .onOpenURL { url in
            deepLinks.handle(url)
            if deepLinks.pendingTemplateID != nil {
                selectedTab = .templates
            }
        }
        .fullScreenCover(isPresented: .constant(!personalization.hasOnboarded)) {
            InterestOnboardingView()
        }
    }
}
