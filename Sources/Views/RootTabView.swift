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

struct RootTabView: View {
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
    }
}
