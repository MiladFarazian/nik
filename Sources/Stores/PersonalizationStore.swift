import Foundation

/// On-device, privacy-preserving personalization for template ranking. Nothing leaves
/// the device: explicit interests (from onboarding) and implicit affinity (from views,
/// uses, and exports) are persisted as a single JSON blob in `UserDefaults`.
///
/// The model is deliberately simple and interpretable:
///  - `interests` — hard signal the user picked in onboarding (tag strings).
///  - `affinity` — soft signal learned from behavior, keyed by tag AND by
///    `"cat:<categoryRawValue>"`, decayed exponentially over time so stale taste fades.
///  - `seenCounts` — per-template fatigue: templates the user keeps scrolling past but
///    never commits to get demoted.
///  - `usedIds` — templates the user actually committed to a project; exempts them from
///    the fatigue penalty (you don't get punished for seeing a template you use a lot).
@MainActor
@Observable
final class PersonalizationStore {
    // MARK: Persisted state

    /// Explicit interests chosen in onboarding (tag strings, e.g. "travel", "meme").
    private(set) var interests: Set<String> = []
    /// Whether the one-time interest onboarding has been shown/dismissed.
    private(set) var hasOnboarded: Bool = false
    /// Implicit taste weights, keyed by tag and by "cat:<categoryRawValue>". Each capped at 10.
    private(set) var affinity: [String: Double] = [:]
    /// Per-template-id view counts, used to demote over-seen-but-never-used templates.
    private(set) var seenCounts: [String: Int] = [:]
    /// Template ids the user has committed to a project — exempt from fatigue.
    private(set) var usedIds: Set<String> = []
    /// Last time exponential decay was applied to `affinity`.
    private var lastDecayDate: Date = Date()

    // MARK: Tuning constants

    private static let affinityCap: Double = 10
    private static let decayPerDay: Double = 0.9

    private static let viewWeight: Double = 0.2
    private static let useWeight: Double = 1.0
    private static let exportWeight: Double = 2.0

    private static let defaultsKey = "nik.personalization.v1"

    // MARK: Init

    init() {
        load()
        applyDecay()
    }

    // MARK: - Onboarding

    /// Records the user's onboarding choices (any count, including zero) and marks
    /// onboarding complete so the cover never shows again.
    func completeOnboarding(interests: Set<String>) {
        self.interests = interests
        hasOnboarded = true
        save()
    }

    /// Marks onboarding complete without changing interests (the "Skip" path).
    func skipOnboarding() {
        hasOnboarded = true
        save()
    }

    // MARK: - Event API

    /// A template surfaced to the user in the pager. Small positive signal + fatigue bump.
    func recordView(_ template: Template) {
        seenCounts[template.id, default: 0] += 1
        bump(template, by: Self.viewWeight)
        save()
    }

    /// The user committed this template to a project. Strong positive signal; also
    /// exempts the template from the fatigue penalty going forward.
    func recordUse(_ template: Template) {
        usedIds.insert(template.id)
        bump(template, by: Self.useWeight)
        save()
    }

    /// The user exported a video built from this template — the strongest signal we have.
    func recordExport(_ template: Template) {
        bump(template, by: Self.exportWeight)
        save()
    }

    /// Adds `delta` to every tag key and the category key for `template`, capping each at 10.
    private func bump(_ template: Template, by delta: Double) {
        for key in keys(for: template) {
            affinity[key] = min((affinity[key] ?? 0) + delta, Self.affinityCap)
        }
    }

    private func keys(for template: Template) -> [String] {
        (template.tags ?? []) + ["cat:\(template.category.rawValue)"]
    }

    // MARK: - Scoring

    /// Blends real-world trend strength, learned affinity, explicit interests, raw
    /// popularity, and per-template fatigue into a single rank score. Higher = show sooner.
    func score(_ template: Template) -> Double {
        // Trend: editorial strength faded by how old the trend is (never below 35%).
        let rawTrend = template.trend?.score ?? 25
        let ageDays = template.trend?.ageDays ?? 30
        // Clamp both ends: floor keeps aged trends visible; ceiling stops a
        // future-dated trend (authoring typo / clock skew) from over-ranking.
        let freshness = min(1, max(0.35, 1 - ageDays / 45))
        let trend = rawTrend * freshness

        // Affinity: learned taste for this template's tags + its category.
        let affinitySum = keys(for: template).reduce(0.0) { $0 + (affinity[$1] ?? 0) }
        let affinityScore = affinitySum * 8

        // Interest: hard boost when a template tag matches an onboarding pick.
        let tags = template.tags ?? []
        let interestBoost = tags.contains(where: interests.contains) ? 18.0 : 0.0

        // Popularity: log-scaled global usage so megahits don't crush everything.
        let popularity = log10(Double(max(template.usageCount, 1))) * 3

        // Fatigue: demote templates seen a lot but never used. Capped, and skipped
        // entirely once the user has committed this template to a project.
        let fatigue: Double = usedIds.contains(template.id)
            ? 0
            : -min(Double(seenCounts[template.id] ?? 0) * 1.5, 12)

        return trend + affinityScore + interestBoost + popularity + fatigue
    }

    /// Stable sort of `templates` by descending score (ties keep their original order).
    func ranked(_ templates: [Template]) -> [Template] {
        templates.enumerated()
            .sorted { lhs, rhs in
                let ls = score(lhs.element), rs = score(rhs.element)
                if ls == rs { return lhs.offset < rhs.offset }
                return ls > rs
            }
            .map(\.element)
    }

    // MARK: - Decay

    /// Exponentially decays all affinity weights by 0.9 per whole day elapsed since the
    /// last decay, then advances the decay date. Keeps taste responsive to recent behavior.
    private func applyDecay() {
        let days = Date().timeIntervalSince(lastDecayDate) / 86_400
        let wholeDays = days.rounded(.down)
        guard wholeDays >= 1 else { return }
        let factor = pow(Self.decayPerDay, wholeDays)
        for key in affinity.keys {
            affinity[key] = (affinity[key] ?? 0) * factor
        }
        // Advance by the whole days consumed, not to now, so the sub-day remainder
        // carries forward (otherwise frequent launches decay slower than 0.9/day).
        lastDecayDate = lastDecayDate.addingTimeInterval(wholeDays * 86_400)
        save()
    }

    // MARK: - Persistence

    private struct Blob: Codable {
        var interests: [String]
        var hasOnboarded: Bool
        var affinity: [String: Double]
        var seenCounts: [String: Int]
        var usedIds: [String]
        var lastDecayDate: Date
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let blob = try? JSONDecoder().decode(Blob.self, from: data) else { return }
        interests = Set(blob.interests)
        hasOnboarded = blob.hasOnboarded
        affinity = blob.affinity
        seenCounts = blob.seenCounts
        usedIds = Set(blob.usedIds)
        lastDecayDate = blob.lastDecayDate
    }

    private func save() {
        let blob = Blob(
            interests: Array(interests),
            hasOnboarded: hasOnboarded,
            affinity: affinity,
            seenCounts: seenCounts,
            usedIds: Array(usedIds),
            lastDecayDate: lastDecayDate
        )
        if let data = try? JSONEncoder().encode(blob) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
