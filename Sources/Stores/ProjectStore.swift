import Foundation

/// Persists projects as JSON under Application Support, with each project's
/// copied media living in Projects/<id>/media/.
@Observable
final class ProjectStore {
    private(set) var projects: [EditProject] = []

    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        load()
    }

    static func mediaDirectory(for projectID: UUID) -> URL {
        let dir = root.appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        projects = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(EditProject.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ project: EditProject) {
        var updated = project
        updated.updatedAt = Date()
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = updated
        } else {
            projects.insert(updated, at: 0)
        }
        projects.sort { $0.updatedAt > $1.updatedAt }
        let url = Self.root.appendingPathComponent("\(project.id.uuidString).json")
        if let data = try? JSONEncoder().encode(updated) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func delete(_ project: EditProject) {
        projects.removeAll { $0.id == project.id }
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent("\(project.id.uuidString).json"))
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(project.id.uuidString, isDirectory: true))
    }
}
