import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics

/// Interpolation curve for a transform ramp.
enum Easing: Sendable {
    case linear
    case easeOut   // decelerating — natural for a zoom "settle" or punch "pop"

    func apply(_ p: CGFloat) -> CGFloat {
        switch self {
        case .linear: return p
        case .easeOut: return 1 - (1 - p) * (1 - p)
        }
    }
}

/// Immutable render description for one video layer (foreground or background)
/// inside a `NikInstruction`. Transforms are expressed in AVFoundation video space
/// (top-left origin, y-down) exactly as the old `AVMutableVideoCompositionLayerInstruction`
/// path used them; the compositor converts to Core Image space when rendering.
///
/// Ramps are **absolute-timed** (rampStart / fade ranges are composition times), so a
/// single logical layer can be split across several instruction time ranges without
/// its animation restarting.
///
/// Immutable value type; it is carried inside the `@unchecked Sendable`
/// `NikInstruction`, so it needs no `Sendable` conformance of its own.
struct LayerSpec {
    let trackID: CMPersistentTrackID
    let sourceHeight: CGFloat            // raw natural height of the source track — for the CI vertical flip

    // Transform ramp (CG/AV space), sampled by absolute composition time.
    let startTransform: CGAffineTransform
    let endTransform: CGAffineTransform
    let rampStart: CMTime
    let rampDuration: CMTime             // 0 == static (always endTransform)
    let easing: Easing

    // Opacity envelope — the product of an optional fade-in (0→1) and fade-out (1→0).
    let fadeIn: CMTimeRange?
    let fadeOut: CMTimeRange?

    let filter: FilterKind

    init(
        trackID: CMPersistentTrackID,
        sourceHeight: CGFloat,
        startTransform: CGAffineTransform,
        endTransform: CGAffineTransform,
        rampStart: CMTime = .zero,
        rampDuration: CMTime = .zero,
        easing: Easing = .linear,
        fadeIn: CMTimeRange? = nil,
        fadeOut: CMTimeRange? = nil,
        filter: FilterKind = .none
    ) {
        self.trackID = trackID
        self.sourceHeight = sourceHeight
        self.startTransform = startTransform
        self.endTransform = endTransform
        self.rampStart = rampStart
        self.rampDuration = rampDuration
        self.easing = easing
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.filter = filter
    }

    /// A static (non-animated, fully opaque) layer — used for crossfade backgrounds.
    static func fixed(
        trackID: CMPersistentTrackID, sourceHeight: CGFloat,
        transform: CGAffineTransform, filter: FilterKind
    ) -> LayerSpec {
        LayerSpec(trackID: trackID, sourceHeight: sourceHeight,
                  startTransform: transform, endTransform: transform, filter: filter)
    }
}

/// A thread-safe, immutable snapshot of one composition time range for the custom
/// `NikCompositor`. Conforms to `AVVideoCompositionInstructionProtocol`.
///
/// `@unchecked Sendable`: every stored member is an immutable value snapshot; the
/// instruction is only read (never mutated) on the compositor's render thread.
final class NikInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let foreground: LayerSpec
    let background: LayerSpec?      // outgoing clip during an A/B-roll crossfade
    let overlay: OverlaySpec?       // shared text/caption/watermark snapshot (export only)

    init(timeRange: CMTimeRange, foreground: LayerSpec, background: LayerSpec?, overlay: OverlaySpec?) {
        self.timeRange = timeRange
        self.foreground = foreground
        self.background = background
        self.overlay = overlay
        var ids: [NSValue] = [NSNumber(value: foreground.trackID)]
        if let background { ids.append(NSNumber(value: background.trackID)) }
        self.requiredSourceTrackIDs = ids
        super.init()
    }
}
