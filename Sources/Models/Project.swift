import Foundation
import CoreGraphics

/// A user's clip assigned to a template slot.
struct SlotFill: Codable, Identifiable, Hashable {
    var id: Int                  // slot index this fill belongs to
    var assetLocalIdentifier: String  // PHAsset localIdentifier
    var isVideo: Bool
    var trimStart: Double        // seconds into the source clip where the slot window begins
    var muted: Bool

    init(id: Int, assetLocalIdentifier: String, isVideo: Bool, trimStart: Double = 0, muted: Bool = false) {
        self.id = id
        self.assetLocalIdentifier = assetLocalIdentifier
        self.isVideo = isVideo
        self.trimStart = trimStart
        self.muted = muted
    }
}

/// One auto-generated (or hand-written) caption segment with word timings for karaoke styles.
struct CaptionSegment: Codable, Identifiable, Hashable {
    var id: UUID
    var text: String
    var start: Double
    var duration: Double
    var words: [CaptionWord]

    init(text: String, start: Double, duration: Double, words: [CaptionWord] = []) {
        self.id = UUID()
        self.text = text
        self.start = start
        self.duration = duration
        self.words = words
    }
}

struct CaptionWord: Codable, Hashable {
    var text: String
    var start: Double
    var duration: Double
}

enum CaptionStyle: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case plain = "Plain"
    case karaoke = "Karaoke"
    case bounce = "Bounce"
    case block = "Block"

    var id: String { rawValue }
}

struct ExportSettings: Codable, Hashable {
    enum Resolution: String, Codable, CaseIterable, Identifiable {
        case p720 = "720p"
        case p1080 = "1080p"
        case p2160 = "4K"

        var id: String { rawValue }
        var size: CGSize {
            switch self {
            case .p720: return CGSize(width: 720, height: 1280)
            case .p1080: return CGSize(width: 1080, height: 1920)
            case .p2160: return CGSize(width: 2160, height: 3840)
            }
        }
        var isPro: Bool { self == .p2160 }
    }

    var resolution: Resolution = .p1080
    var frameRate: Int = 30
    var watermark: Bool = true
}

/// A draft or completed edit: template + the user's fills + caption state.
struct EditProject: Codable, Identifiable, Hashable {
    var id: UUID
    var templateID: String
    var createdAt: Date
    var updatedAt: Date
    var fills: [SlotFill]
    var textLayers: [TextLayerSpec]     // copied from template, user-editable
    var captions: [CaptionSegment]
    var captionStyle: CaptionStyle
    var musicAssetIdentifier: String?   // optional user-picked music video/audio asset
    var exportSettings: ExportSettings

    init(template: Template, fills: [SlotFill]) {
        self.id = UUID()
        self.templateID = template.id
        self.createdAt = Date()
        self.updatedAt = Date()
        self.fills = fills
        self.textLayers = template.textLayers
        self.captions = []
        self.captionStyle = .none
        self.musicAssetIdentifier = nil
        self.exportSettings = ExportSettings()
    }
}
