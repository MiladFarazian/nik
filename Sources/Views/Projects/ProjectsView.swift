import SwiftUI

struct ProjectsView: View {
    @Environment(ProjectStore.self) private var projectStore
    @Environment(TemplateStore.self) private var templateStore
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if projectStore.projects.isEmpty {
                    ContentUnavailableView(
                        "No projects yet",
                        systemImage: "film.stack",
                        description: Text("Pick a template to make your first video.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                            spacing: 14
                        ) {
                            ForEach(projectStore.projects) { project in
                                projectCard(project)
                            }
                        }
                        .padding(12)
                        .padding(.bottom, 24)   // clear the floating tab bar
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("Projects")
            .navigationDestination(for: EditorRoute.self) { route in
                EditorView(projectID: route.projectID, path: $path)
            }
        }
    }

    @ViewBuilder
    private func projectCard(_ project: EditProject) -> some View {
        let template = templateStore.template(id: project.templateID)
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let template {
                    AnimatedTemplatePreview(template: template)
                } else {
                    Theme.surface2
                }
            }
            .aspectRatio(9 / 16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottomLeading) {
                if let template {
                    Text(template.durationLabel)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                }
            }

            Text(template?.name ?? "Project")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(project.updatedAt.formatted(.relative(presentation: .named)))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        .onTapGesture {
            guard template != nil else { return }
            Haptics.selection()
            path.append(EditorRoute(projectID: project.id))
        }
        .contextMenu {
            Button(role: .destructive) {
                projectStore.delete(project)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
