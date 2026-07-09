import Foundation

/// Template catalog: compiled-in built-ins as the floor, optionally extended by a
/// server-delivered JSON catalog (see catalog/catalog.json for the format). Remote
/// templates merge over built-ins by id; a decode failure never clobbers anything.
@MainActor
@Observable
final class TemplateStore {
    /// Remote catalog location. Points at the repo's main-branch catalog so new
    /// trends ship by pushing to GitHub — no app update. Set to nil for offline-only.
    nonisolated(unsafe) static var catalogURL: URL? =
        URL(string: "https://raw.githubusercontent.com/MiladFarazian/nik/main/catalog/catalog.json")

    private(set) var templates: [Template] = TemplateStore.builtIns

    private struct Catalog: Codable {
        var schemaVersion: Int
        var templates: [Template]
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catalog-cache.json")
    }

    init() {
        // Bundled catalog ships with the app so its templates are available offline.
        if let url = Bundle.main.url(forResource: "catalog", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            apply(catalogData: data, persist: false)
        }
        // A previously-fetched remote catalog (newer than the bundle) wins over it.
        if let data = try? Data(contentsOf: Self.cacheURL) {
            apply(catalogData: data, persist: false)
        }
    }

    /// Fetches the remote catalog and merges it over the built-ins. Safe to call
    /// repeatedly (e.g. on foreground); failures leave the current state untouched.
    func refresh() async {
        guard let url = Self.catalogURL else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
            apply(catalogData: data, persist: true)
        } catch {
            // Offline or server error — keep whatever we have.
        }
    }

    private func apply(catalogData: Data, persist: Bool) {
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: catalogData),
              catalog.schemaVersion == 1 else { return }
        var merged = Dictionary(uniqueKeysWithValues: Self.builtIns.map { ($0.id, $0) })
        for template in catalog.templates {
            merged[template.id] = template   // remote wins on id collision
        }
        // Built-ins keep their curated order; remote-only templates append by usage.
        let builtInIDs = Self.builtIns.map(\.id)
        templates = builtInIDs.compactMap { merged[$0] }
            + catalog.templates.filter { !builtInIDs.contains($0.id) }.sorted { $0.usageCount > $1.usageCount }
        if persist {
            try? catalogData.write(to: Self.cacheURL, options: .atomic)
        }
    }

    func template(id: String) -> Template? {
        templates.first { $0.id == id }
    }

    func templates(in category: TemplateCategory) -> [Template] {
        category == .forYou ? templates : templates.filter { $0.category == category }
    }

    // MARK: - Built-in catalog

    static let builtIns: [Template] = [
        Template(
            id: "hook-punch-01", name: "Hook & Punch", author: "nik",
            category: .trending,
            slots: [
                TemplateSlot(id: 0, duration: 1.8, transition: .punchIn, hint: "attention-grabbing opener"),
                TemplateSlot(id: 1, duration: 1.2, transition: .cut, hint: "quick detail"),
                TemplateSlot(id: 2, duration: 1.2, transition: .cut, hint: "quick detail"),
                TemplateSlot(id: 3, duration: 2.4, transition: .zoomIn, hint: "the payoff"),
            ],
            textLayers: [
                TextLayerSpec(text: "WAIT FOR IT…", start: 0, duration: 1.8, relativeY: 0.24, fontSize: 84, style: .outlined),
                TextLayerSpec(text: "worth it 🔥", start: 4.2, duration: 2.4, relativeY: 0.72, fontSize: 68, style: .block),
            ],
            music: MusicSpec(name: "Punchy Beat", bpm: 100, beatTimes: [0, 0.6, 1.2, 1.8, 2.4, 3.0, 3.6, 4.2, 4.8, 5.4, 6.0]),
            usageCount: 1_240_000, isPro: false,
            previewColors: ["#9B5CFF", "#FF5C9B"]
        ),
        Template(
            id: "photo-dump-01", name: "Photo Dump", author: "nik",
            category: .photoDump,
            slots: (0..<8).map { TemplateSlot(id: $0, duration: 0.8, transition: $0 == 0 ? .zoomIn : .cut) },
            textLayers: [
                TextLayerSpec(text: "recently 📸", start: 0, duration: 1.6, relativeY: 0.2, fontSize: 76, style: .block),
            ],
            music: MusicSpec(name: "Lofi Flip", bpm: 75, beatTimes: (0..<9).map { Double($0) * 0.8 }),
            usageCount: 2_890_000, isPro: false,
            previewColors: ["#FFB35C", "#FF5C5C"]
        ),
        Template(
            id: "day-in-life-01", name: "Day In The Life", author: "nik",
            category: .vlog,
            slots: [
                TemplateSlot(id: 0, duration: 2.0, transition: .crossfade, hint: "morning"),
                TemplateSlot(id: 1, duration: 1.5, transition: .cut, hint: "coffee / commute"),
                TemplateSlot(id: 2, duration: 1.5, transition: .cut, hint: "work / activity"),
                TemplateSlot(id: 3, duration: 1.5, transition: .crossfade, hint: "food"),
                TemplateSlot(id: 4, duration: 1.5, transition: .cut, hint: "golden hour"),
                TemplateSlot(id: 5, duration: 2.5, transition: .crossfade, hint: "wind down"),
            ],
            textLayers: [
                TextLayerSpec(text: "a day in my life", start: 0.2, duration: 1.8, relativeY: 0.5, fontSize: 72, style: .bold),
            ],
            music: MusicSpec(name: "Warm Keys", bpm: 80, beatTimes: nil),
            usageCount: 860_000, isPro: false,
            previewColors: ["#5CFFB0", "#5C9BFF"]
        ),
        Template(
            id: "velocity-01", name: "Velocity Rush", author: "nik",
            category: .velocity,
            slots: [
                TemplateSlot(id: 0, duration: 1.0, transition: .cut, speed: 0.5, hint: "slow-mo moment"),
                TemplateSlot(id: 1, duration: 0.5, transition: .punchIn, speed: 2.0, hint: "fast action"),
                TemplateSlot(id: 2, duration: 0.5, transition: .cut, speed: 2.0, hint: "fast action"),
                TemplateSlot(id: 3, duration: 1.5, transition: .punchIn, speed: 0.5, hint: "hero slow-mo"),
                TemplateSlot(id: 4, duration: 1.0, transition: .cut, speed: 1.0, hint: "closer"),
            ],
            textLayers: [],
            music: MusicSpec(name: "Phonk Drift", bpm: 130, beatTimes: [0, 0.46, 0.92, 1.38, 1.84, 2.3, 2.77, 3.23, 3.69, 4.15]),
            usageCount: 3_400_000, isPro: true,
            previewColors: ["#FF5C5C", "#9B5CFF"]
        ),
        Template(
            id: "travel-recap-01", name: "Travel Recap", author: "nik",
            category: .travel,
            slots: [
                TemplateSlot(id: 0, duration: 2.2, transition: .zoomIn, hint: "arrival / plane window"),
                TemplateSlot(id: 1, duration: 1.4, transition: .crossfade, hint: "landscape"),
                TemplateSlot(id: 2, duration: 1.4, transition: .cut, hint: "food"),
                TemplateSlot(id: 3, duration: 1.4, transition: .cut, hint: "people"),
                TemplateSlot(id: 4, duration: 1.4, transition: .crossfade, hint: "detail shot"),
                TemplateSlot(id: 5, duration: 2.6, transition: .zoomIn, hint: "best view"),
            ],
            textLayers: [
                TextLayerSpec(text: "POV: you finally went", start: 0.3, duration: 2.0, relativeY: 0.26, fontSize: 70, style: .outlined),
            ],
            music: MusicSpec(name: "Golden Air", bpm: 90, beatTimes: nil),
            usageCount: 1_950_000, isPro: false,
            previewColors: ["#5C9BFF", "#5CFFE8"]
        ),
        Template(
            id: "before-after-01", name: "Before / After", author: "nik",
            category: .business,
            slots: [
                TemplateSlot(id: 0, duration: 2.5, transition: .cut, hint: "the before"),
                TemplateSlot(id: 1, duration: 3.0, transition: .punchIn, hint: "the after / reveal"),
            ],
            textLayers: [
                TextLayerSpec(text: "BEFORE", start: 0, duration: 2.5, relativeY: 0.22, fontSize: 88, style: .block),
                TextLayerSpec(text: "AFTER ✨", start: 2.5, duration: 3.0, relativeY: 0.22, fontSize: 88, style: .block),
            ],
            music: MusicSpec(name: "Reveal Hit", bpm: 95, beatTimes: [0, 2.5]),
            usageCount: 720_000, isPro: false,
            previewColors: ["#FFC94D", "#FF5C9B"]
        ),
        Template(
            id: "meme-caption-01", name: "Meme Caption", author: "nik",
            category: .memes,
            slots: [
                TemplateSlot(id: 0, duration: 5.0, transition: .cut, hint: "the moment"),
            ],
            textLayers: [
                TextLayerSpec(text: "me pretending to work", start: 0, duration: 5.0, relativeY: 0.14, fontSize: 66, style: .block),
            ],
            music: nil,
            usageCount: 4_100_000, isPro: false,
            previewColors: ["#24FF6F", "#FFC94D"]
        ),
        Template(
            id: "grwm-01", name: "Get Ready With Me", author: "nik",
            category: .vlog,
            slots: [
                TemplateSlot(id: 0, duration: 1.6, transition: .cut, hint: "starting point"),
                TemplateSlot(id: 1, duration: 1.2, transition: .cut, hint: "step 1"),
                TemplateSlot(id: 2, duration: 1.2, transition: .cut, hint: "step 2"),
                TemplateSlot(id: 3, duration: 1.2, transition: .cut, hint: "step 3"),
                TemplateSlot(id: 4, duration: 2.8, transition: .zoomIn, hint: "final look"),
            ],
            textLayers: [
                TextLayerSpec(text: "GRWM ✨", start: 0, duration: 1.6, relativeY: 0.24, fontSize: 80, style: .outlined),
            ],
            music: MusicSpec(name: "Pop Sparkle", bpm: 110, beatTimes: nil),
            usageCount: 1_310_000, isPro: true,
            previewColors: ["#FF5C9B", "#FFB35C"]
        ),
    ]
}
