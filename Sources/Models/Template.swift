import Foundation
import CoreGraphics

/// Decodes a raw-`String`-backed enum, substituting `fallback` when the JSON value
/// doesn't match any case this build knows about. This is what lets an older, already-
/// shipped app safely ingest a server-delivered catalog (`catalog/catalog.json`) that
/// introduces a new category/transition/filter after the app was released, instead of
/// throwing a decode error that would take down the whole catalog (or a persisted
/// `EditProject`, which embeds these same enums via `TextLayerSpec`/`TemplateSlot`).
enum RawValueFallbackDecoding {
    static func decode<T: RawRepresentable>(_ type: T.Type, from decoder: Decoder, fallback: T) throws -> T where T.RawValue == String {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        return T(rawValue: raw) ?? fallback
    }
}

/// How a slot's clip enters the frame.
enum TransitionKind: String, Codable, CaseIterable {
    case cut
    case crossfade
    case zoomIn      // clip starts slightly zoomed and settles
    case punchIn     // instant 1.15x scale for emphasis

    // Unknown raw values (e.g. a newer server category) fall back to `.cut` rather than
    // failing the whole decode. `encode(to:)` remains compiler-synthesized from rawValue.
    init(from decoder: Decoder) throws {
        self = try RawValueFallbackDecoding.decode(Self.self, from: decoder, fallback: .cut)
    }
}

/// A color grade applied to a slot's clip by the custom compositor (Core Image).
enum FilterKind: String, Codable, CaseIterable {
    case none        // passthrough
    case warm        // CITemperatureAndTint, warmer target neutral
    case cool        // CITemperatureAndTint, cooler target neutral
    case mono        // CIPhotoEffectMono
    case vivid       // CIColorControls: boosted saturation + slight contrast

    // Unknown raw values fall back to `.none` (passthrough) so an unrecognized filter
    // never blocks the rest of the template from decoding.
    init(from decoder: Decoder) throws {
        self = try RawValueFallbackDecoding.decode(Self.self, from: decoder, fallback: .none)
    }
}

/// One fillable segment of a template.
struct TemplateSlot: Codable, Identifiable, Hashable {
    var id: Int              // slot index, 0-based
    var duration: Double     // seconds the slot plays
    var transition: TransitionKind
    var speed: Double        // playback rate applied to the source clip (1.0 = normal)
    var hint: String?        // e.g. "wide shot", "close-up of product"
    var filter: FilterKind?  // optional color grade; nil == .none. Decodes back-compat via optional.

    init(id: Int, duration: Double, transition: TransitionKind = .cut, speed: Double = 1.0,
         hint: String? = nil, filter: FilterKind? = nil) {
        self.id = id
        self.duration = duration
        self.transition = transition
        self.speed = speed
        self.hint = hint
        self.filter = filter
    }
}

/// A text overlay baked into the template (hook text, punchline, CTA).
struct TextLayerSpec: Codable, Identifiable, Hashable {
    var id: UUID
    var text: String
    var start: Double        // seconds into the timeline
    var duration: Double
    var relativeY: CGFloat   // 0 = top, 1 = bottom (position of the text block center)
    var fontSize: CGFloat    // in 1080x1920 output points
    var style: TextStyle

    enum TextStyle: String, Codable, CaseIterable {
        case bold          // heavy white with shadow
        case outlined      // white fill, black stroke (TikTok classic)
        case block         // white text on rounded black block
        case caption       // smaller, lower-third
    }

    init(text: String, start: Double, duration: Double, relativeY: CGFloat = 0.28,
         fontSize: CGFloat = 72, style: TextStyle = .outlined) {
        self.id = UUID()
        self.text = text
        self.start = start
        self.duration = duration
        self.relativeY = relativeY
        self.fontSize = fontSize
        self.style = style
    }
}

/// Template music spec. v1 ships silent/beat-grid templates; the user's clip audio
/// or an imported track fills the audio bed.
struct MusicSpec: Codable, Hashable {
    var name: String
    var bpm: Double?
    /// Beat times (seconds) — slot boundaries are aligned to these when authoring templates.
    var beatTimes: [Double]?
}

enum TemplateCategory: String, Codable, CaseIterable, Identifiable {
    case forYou = "For You"
    case trending = "Trending"
    case vlog = "Vlog"
    case travel = "Travel"
    case photoDump = "Photo Dump"
    case business = "Business"
    case velocity = "Velocity"
    case memes = "Memes"

    var id: String { rawValue }

    // Unknown raw values (a new category added server-side after this app version
    // shipped) fall back to `.trending` so new templates still show up somewhere
    // instead of failing catalog decode entirely.
    init(from decoder: Decoder) throws {
        self = try RawValueFallbackDecoding.decode(Self.self, from: decoder, fallback: .trending)
    }
}

struct Template: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var author: String
    var category: TemplateCategory
    var slots: [TemplateSlot]
    var textLayers: [TextLayerSpec]
    var music: MusicSpec?
    var usageCount: Int
    var isPro: Bool
    /// Two hex colors used to render the animated placeholder preview card.
    var previewColors: [String]

    var duration: Double { slots.reduce(0) { $0 + $1.duration } }
    var clipCount: Int { slots.count }

    var durationLabel: String {
        let secs = Int(duration.rounded())
        return String(format: "0:%02d", secs)
    }

    var usageLabel: String {
        usageCount >= 1_000_000 ? String(format: "%.1fM", Double(usageCount) / 1_000_000)
        : usageCount >= 1_000 ? String(format: "%.1fK", Double(usageCount) / 1_000)
        : "\(usageCount)"
    }

    /// Returns `slots` with durations snapped so each slot boundary lands on the
    /// nearest music beat, when `music?.beatTimes` is available. Pure function — no
    /// side effects, not wired into any flow yet; the v2 orchestrator decides where/if
    /// to apply beat-aligned durations before building a composition.
    ///
    /// Algorithm: walk the slots in order, tracking `previousBoundary` (the last
    /// aligned cut point) and `naturalBoundary` (where the boundary would fall using
    /// the *original*, un-aligned durations). For each slot:
    ///   1. Compute `minBoundary = previousBoundary + 0.4` — the earliest this
    ///      boundary may land, guaranteeing the slot is never shorter than 0.4s.
    ///   2. Among beat times `>= minBoundary`, pick the one nearest to
    ///      `naturalBoundary` (the slot's un-aligned target end time).
    ///   3. If no beat clears `minBoundary` (grid too short/sparse for the remaining
    ///      slots), fall back to `max(naturalBoundary, minBoundary)` so the timeline
    ///      still advances instead of stalling.
    /// The new duration is `newBoundary - previousBoundary`. The last slot's boundary
    /// is whatever beat/fallback that final step lands on — it is not force-snapped to
    /// `beatTimes.last`, so a short trailing beat grid can shorten (but never
    /// eliminate) the final slot.
    ///
    /// Worked example — "Hook & Punch" (`beatTimes`: 0, 0.6, 1.2, 1.8, 2.4, 3.0, 3.6,
    /// 4.2, 4.8, 5.4, 6.0; original slot durations: 1.8, 1.2, 1.2, 2.4):
    ///   - slot 0: previousBoundary 0, naturalBoundary 1.8, minBoundary 0.4.
    ///     Nearest beat >= 0.4 to 1.8 is 1.8 -> boundary 1.8, duration 1.8.
    ///   - slot 1: previousBoundary 1.8, naturalBoundary 3.0, minBoundary 2.2.
    ///     Nearest beat >= 2.2 to 3.0 is 3.0 -> boundary 3.0, duration 1.2.
    ///   - slot 2: previousBoundary 3.0, naturalBoundary 4.2, minBoundary 3.4.
    ///     Nearest beat >= 3.4 to 4.2 is 4.2 -> boundary 4.2, duration 1.2.
    ///   - slot 3 (last): previousBoundary 4.2, naturalBoundary 6.6, minBoundary 4.6.
    ///     Beats >= 4.6 are 4.8, 5.4, 6.0; nearest to 6.6 is 6.0 -> boundary 6.0,
    ///     duration 1.8 (shortened from 2.4 because the beat grid ends at 6.0s).
    ///   Result durations: [1.8, 1.2, 1.2, 1.8].
    func beatAlignedSlots() -> [TemplateSlot] {
        guard let beatTimes = music?.beatTimes, !beatTimes.isEmpty else { return slots }
        let sortedBeats = beatTimes.sorted()
        var result: [TemplateSlot] = []
        var previousBoundary: Double = 0
        var naturalBoundary: Double = 0
        for slot in slots {
            naturalBoundary += slot.duration
            let minBoundary = previousBoundary + 0.4
            let candidates = sortedBeats.filter { $0 >= minBoundary }
            let newBoundary: Double
            if let nearest = candidates.min(by: { abs($0 - naturalBoundary) < abs($1 - naturalBoundary) }) {
                newBoundary = nearest
            } else {
                newBoundary = max(naturalBoundary, minBoundary)
            }
            var aligned = slot
            aligned.duration = newBoundary - previousBoundary
            result.append(aligned)
            previousBoundary = newBoundary
        }
        return result
    }
}
