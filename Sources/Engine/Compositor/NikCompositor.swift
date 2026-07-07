import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreGraphics
import Metal

/// Custom `AVVideoCompositing` that replaces the fragile
/// `AVVideoCompositionCoreAnimationTool` export path with a Core Image compositor.
///
/// - One shared Metal-backed `CIContext` (`.cacheIntermediates = false`).
/// - Stateless per frame except the immutable context / color space; all timing and
///   geometry come from the (immutable, Sendable) `NikInstruction` snapshot, so it is
///   safe to render requests concurrently.
/// - Source and output buffers are 32BGRA; output buffers come from
///   `request.renderContext.newPixelBuffer()`.
/// - Per-frame work is wrapped in an `autoreleasepool`.
final class NikCompositor: NSObject, AVVideoCompositing {

    private let ciContext: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()


    override init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
        super.init()
    }

    // MARK: - AVVideoCompositing pixel formats

    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [Int(kCVPixelFormatType_32BGRA)],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]

    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // Stateless — buffers are pulled from the request's render context per frame.
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Rendering happens synchronously inside startRequest, so no requests are
        // ever pending across calls — nothing to cancel. (A sticky "cancelled" flag
        // here blackens every future frame: AVFoundation calls this on routine
        // seeks/flushes, not just teardown.)
    }

    // MARK: - Rendering

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? NikInstruction else {
                NSLog("NikCompositor: unexpected instruction class %@ at %.3fs",
                      String(describing: type(of: request.videoCompositionInstruction)),
                      request.compositionTime.seconds)
                request.finish(with: CompositorError.badInstruction); return
            }
            guard let output = request.renderContext.newPixelBuffer() else {
                NSLog("NikCompositor: newPixelBuffer returned nil at %.3fs", request.compositionTime.seconds)
                request.finish(with: CompositorError.noBuffer); return
            }

            let renderSize = request.renderContext.size
            let renderRect = CGRect(origin: .zero, size: renderSize)
            let time = request.compositionTime

            var image = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: renderRect)

            if let background = instruction.background,
               let buffer = request.sourceFrame(byTrackID: background.trackID) {
                image = render(layer: background, source: buffer, time: time, renderHeight: renderSize.height)
                    .composited(over: image)
            }

            if let buffer = request.sourceFrame(byTrackID: instruction.foreground.trackID) {
                image = render(layer: instruction.foreground, source: buffer, time: time, renderHeight: renderSize.height)
                    .composited(over: image)
            }

            if let overlay = instruction.overlay {
                image = composite(overlay: overlay, over: image, at: time.seconds, renderHeight: renderSize.height)
            }

            ciContext.render(image, to: output, bounds: renderRect, colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: output)
        }
    }

    // MARK: - Video layer

    private func render(layer: LayerSpec, source: CVPixelBuffer, time: CMTime, renderHeight: CGFloat) -> CIImage {
        var image = CIImage(cvPixelBuffer: source)
        image = applyFilter(layer.filter, to: image)

        let p = progress(time, start: layer.rampStart, duration: layer.rampDuration)
        let cg = interpolate(layer.startTransform, layer.endTransform, layer.easing.apply(p))
        image = image.transformed(by: ciTransform(cg, sourceHeight: layer.sourceHeight, renderHeight: renderHeight))

        let alpha = opacity(of: layer, at: time)
        if alpha < 0.999 { image = faded(image, alpha: alpha) }
        return image
    }

    /// Converts an AVFoundation (top-left, y-down) transform into Core Image
    /// (bottom-left, y-up) space: `flip(sourceHeight) · cg · flip(renderHeight)`.
    private func ciTransform(_ cg: CGAffineTransform, sourceHeight: CGFloat, renderHeight: CGFloat) -> CGAffineTransform {
        let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceHeight)
        let flipRender = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: renderHeight)
        return flipSource.concatenating(cg).concatenating(flipRender)
    }

    private func interpolate(_ a: CGAffineTransform, _ b: CGAffineTransform, _ p: CGFloat) -> CGAffineTransform {
        if p <= 0 { return a }
        if p >= 1 { return b }
        return CGAffineTransform(
            a: a.a + (b.a - a.a) * p, b: a.b + (b.b - a.b) * p,
            c: a.c + (b.c - a.c) * p, d: a.d + (b.d - a.d) * p,
            tx: a.tx + (b.tx - a.tx) * p, ty: a.ty + (b.ty - a.ty) * p
        )
    }

    private func progress(_ time: CMTime, start: CMTime, duration: CMTime) -> CGFloat {
        let d = duration.seconds
        guard d > 0 else { return 1 }
        return CGFloat(max(0, min(1, (time.seconds - start.seconds) / d)))
    }

    private func opacity(of layer: LayerSpec, at time: CMTime) -> CGFloat {
        let t = time.seconds
        var alpha: CGFloat = 1
        if let fadeIn = layer.fadeIn {
            let d = fadeIn.duration.seconds
            alpha *= d <= 0 ? 1 : CGFloat(max(0, min(1, (t - fadeIn.start.seconds) / d)))
        }
        if let fadeOut = layer.fadeOut {
            let d = fadeOut.duration.seconds
            let e = d <= 0 ? 1 : (t - fadeOut.start.seconds) / d
            alpha *= CGFloat(max(0, min(1, 1 - e)))
        }
        return alpha
    }

    // MARK: - Filters (stateless — `applyingFilter` creates a fresh CIFilter each call)

    private func applyFilter(_ kind: FilterKind, to image: CIImage) -> CIImage {
        switch kind {
        case .none:
            return image
        case .warm:
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 7200, y: 12),
            ])
        case .cool:
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 5800, y: -12),
            ])
        case .mono:
            return image.applyingFilter("CIPhotoEffectMono", parameters: [:])
        case .vivid:
            return image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.3,
                kCIInputContrastKey: 1.05,
            ])
        }
    }

    private func faded(_ image: CIImage, alpha: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
        ])
    }

    // MARK: - Overlays

    private func composite(overlay: OverlaySpec, over base: CIImage, at t: Double, renderHeight: CGFloat) -> CIImage {
        var out = base

        for text in overlay.texts where t >= text.start && t <= text.start + text.duration {
            let (scale, alpha) = popIn(elapsed: t - text.start, duration: text.duration)
            out = placed(text.image, frame: text.frame, renderHeight: renderHeight, scale: scale, alpha: alpha)
                .composited(over: out)
        }

        for caption in overlay.captions where t >= caption.start && t <= caption.start + caption.duration {
            let alpha = envelope(elapsed: t - caption.start, duration: caption.duration)
            if let bg = caption.background {
                out = placed(bg, frame: caption.backgroundFrame, renderHeight: renderHeight, scale: 1, alpha: alpha)
                    .composited(over: out)
            }
            for word in caption.words {
                var scale: CGFloat = 1
                if caption.style == .bounce, t >= word.start {
                    let d = min(0.15, word.duration)
                    let e = t - word.start
                    if d > 0, e < d { scale = 1 + 0.2 * CGFloat(sin(Double.pi * (e / d))) }  // 1.0 → 1.2 → 1.0
                }
                out = placed(word.white, frame: word.frame, renderHeight: renderHeight, scale: scale, alpha: alpha)
                    .composited(over: out)
                if caption.style == .karaoke, let accent = word.accent, t >= word.start {
                    out = placed(accent, frame: word.frame, renderHeight: renderHeight, scale: scale, alpha: alpha)
                        .composited(over: out)
                }
            }
        }

        if let watermark = overlay.watermark {
            out = placed(watermark.image, frame: watermark.frame, renderHeight: renderHeight, scale: 1, alpha: 1)
                .composited(over: out)
        }
        return out
    }

    /// Positions a rasterized overlay (extent 0,0,w,h; top-left-authored) at a render
    /// top-left frame in Core Image space, with an optional centered scale + alpha.
    private func placed(_ image: CIImage, frame: CGRect, renderHeight: CGFloat, scale: CGFloat, alpha: CGFloat) -> CIImage {
        let w = frame.width, h = frame.height
        var t = CGAffineTransform.identity
        if abs(scale - 1) > 0.0001 {
            t = CGAffineTransform(translationX: w / 2, y: h / 2)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -w / 2, y: -h / 2)
        }
        let tx = frame.minX
        let ty = renderHeight - frame.minY - h
        t = t.concatenating(CGAffineTransform(translationX: tx, y: ty))
        var out = image.transformed(by: t)
        if alpha < 0.999 { out = faded(out, alpha: alpha) }
        return out
    }

    /// Text pop-in: scale 0.85 → 1.06 → 1.0 and fade 0 → 1 over the first 0.25s,
    /// plus a short fade-out at the very end.
    private func popIn(elapsed e: Double, duration: Double) -> (scale: CGFloat, alpha: CGFloat) {
        guard duration > 0 else { return (1, 1) }
        var scale: CGFloat = 1
        if e < 0.25 {
            let p = e / 0.25
            scale = p < 0.6 ? lerp(0.85, 1.06, CGFloat(p / 0.6)) : lerp(1.06, 1.0, CGFloat((p - 0.6) / 0.4))
        }
        var alpha = CGFloat(min(1, e / 0.12))
        let tail = duration - e
        if tail < 0.1 { alpha *= CGFloat(max(0, tail / 0.1)) }
        return (scale, alpha)
    }

    private func envelope(elapsed e: Double, duration: Double) -> CGFloat {
        guard duration > 0 else { return 1 }
        let fadeIn = CGFloat(min(1, e / 0.08))
        let tail = duration - e
        let fadeOut = tail < 0.08 ? CGFloat(max(0, tail / 0.08)) : 1
        return fadeIn * fadeOut
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a + (b - a) * max(0, min(1, p)) }

    // MARK: -

    private enum CompositorError: Error { case badInstruction, noBuffer }
}
