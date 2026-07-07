import Foundation
import CoreGraphics

/// How a slot's clip enters the frame.
enum TransitionKind: String, Codable, CaseIterable {
    case cut
    case crossfade
    case zoomIn      // clip starts slightly zoomed and settles
    case punchIn     // instant 1.15x scale for emphasis
}

/// A color grade applied to a slot's clip by the custom compositor (Core Image).
enum FilterKind: String, Codable, CaseIterable {
    case none        // passthrough
    case warm        // CITemperatureAndTint, warmer target neutral
    case cool        // CITemperatureAndTint, cooler target neutral
    case mono        // CIPhotoEffectMono
    case vivid       // CIColorControls: boosted saturation + slight contrast
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
}
