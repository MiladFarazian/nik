import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import Vision

/// Vision-driven smart crop for the 9:16 aspect-fill window.
///
/// The plain aspect-fill (see `CompositionBuilder.aspectFillTransform`) centers the
/// source in the render frame; whichever axis overflows is cropped symmetrically.
/// `SmartCrop` keeps the **same fill scale** (it never zooms in past fill) but slides
/// the crop window so the region a human cares about — faces first, then whatever the
/// saliency model finds attention-grabbing — sits in the center, clamped so the source
/// still fully covers the render rect.
///
/// Every coordinate-space hop is spelled out in comments because there are four of them:
///   1. Vision output        — normalized [0,1]², **lower-left origin** (y up).
///   2. Displayed image       — the CGImage the generator hands us already has the track's
///                              `preferredTransform` baked in (`appliesPreferredTrackTransform`),
///                              so it is upright and its normalized frame == the "displayed"
///                              size used by `aspectFillTransform`. We convert Vision's y-up
///                              coordinates to a top-left normalized (u,v) here.
///   3. Displayed→render      — the aspect-fill scale maps the displayed content to a rect
///                              of size (Wc,Hc) in AV render space (top-left origin, y-down).
///   4. Render → source       — the returned transform is exactly `aspectFillTransform`'s
///                              output plus a render-space translation, so it lives in the
///                              same AV video space every other base transform uses and the
///                              compositor's `flip(sourceH)·T·flip(renderH)` conversion is
///                              unchanged.
enum SmartCrop {

    /// Aspect-fill geometry facts, all in AV render space (top-left origin).
    struct FillMetrics {
        /// The displayed source content after the aspect-fill scale: (Wc, Hc).
        let contentSize: CGSize
        /// Maximum render-space translation the window can slide and still cover the
        /// render rect: half the horizontal / vertical overflow. Zero when that axis
        /// exactly fills (no room to pan).
        let maxPanX: CGFloat
        let maxPanY: CGFloat
    }

    /// Geometry of a plain aspect-fill of `naturalSize` (rotated by `preferredTransform`)
    /// into `renderSize`. Mirrors the scale math in `CompositionBuilder.aspectFillTransform`
    /// so the smart/override translation is expressed against the identical content rect.
    static func fillMetrics(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> FillMetrics {
        // Displayed size = natural size after the preferred (rotation) transform, absolute.
        let displayedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displayedW = abs(displayedRect.width)
        let displayedH = abs(displayedRect.height)
        guard displayedW > 0, displayedH > 0, renderSize.width > 0, renderSize.height > 0 else {
            return FillMetrics(contentSize: .zero, maxPanX: 0, maxPanY: 0)
        }
        // Aspect *fill*: the larger of the two axis ratios — one axis fills exactly, the
        // other overflows. Never < 1-vs-fill; we never scale up beyond this.
        let scale = max(renderSize.width / displayedW, renderSize.height / displayedH)
        let wc = displayedW * scale
        let hc = displayedH * scale
        return FillMetrics(
            contentSize: CGSize(width: wc, height: hc),
            maxPanX: max(0, (wc - renderSize.width) / 2),
            maxPanY: max(0, (hc - renderSize.height) / 2)
        )
    }

    /// Apply a render-space pan (in points) to a centered aspect-fill transform, clamped to
    /// the fill overflow so the source keeps covering the render rect. `dx>0` moves the
    /// content right (reveals more of the left of the source); `dy>0` moves it down.
    ///
    /// Because the pan is a render-space translation concatenated *after* the base transform,
    /// it commutes with the centered fill's own translation — the result is still
    /// `scaled · translate(chosen_tx, chosen_ty)`, i.e. identical in form to
    /// `aspectFillTransform`, just re-centered.
    static func panned(
        _ centered: CGAffineTransform,
        dx: CGFloat,
        dy: CGFloat,
        metrics: FillMetrics
    ) -> CGAffineTransform {
        let cdx = max(-metrics.maxPanX, min(metrics.maxPanX, dx))
        let cdy = max(-metrics.maxPanY, min(metrics.maxPanY, dy))
        return centered.concatenating(CGAffineTransform(translationX: cdx, y: cdy))
    }

    /// Returns a smart aspect-fill transform (same scale as a plain fill, translation chosen
    /// to center the interest union) in AV video space, or `nil` when there is no usable
    /// signal (no faces and only weak saliency, no overflow to pan into, or any Vision error).
    ///
    /// - Parameters:
    ///   - assetURL: source clip (a fresh `AVURLAsset` is created here — never share the
    ///     builder's asset across the concurrent task group).
    ///   - sourceRange: the slot's window in source time. A zero-duration range (photos)
    ///     analyzes a single frame.
    ///   - naturalSize / preferredTransform: the source video track's raw size & rotation.
    ///   - renderSize: the 9:16 output size.
    static func cropTransform(
        for assetURL: URL,
        sourceRange: CMTimeRange,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) async -> CGAffineTransform? {
        do {
            let metrics = fillMetrics(
                naturalSize: naturalSize, preferredTransform: preferredTransform, renderSize: renderSize
            )
            // No overflow on either axis → panning is a no-op; let the caller use plain fill.
            guard metrics.maxPanX > 0.5 || metrics.maxPanY > 0.5 else { return nil }

            let asset = AVURLAsset(url: assetURL)
            let generator = AVAssetImageGenerator(asset: asset)
            // Upright frames in *displayed* orientation — so Vision's normalized rects live in
            // the same displayed space as `fillMetrics`, and we can use orientation .up below.
            generator.appliesPreferredTrackTransform = true
            // Cap the analysis resolution (aspect-preserving); 720 is plenty for detection.
            generator.maximumSize = CGSize(width: 720, height: 720)
            // Generous tolerance: snap to nearby keyframes, don't decode-exact (fast).
            let tol = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tol
            generator.requestedTimeToleranceAfter = tol

            // --- Space 1→2: accumulate a weighted centroid in Vision's normalized,
            // lower-left-origin space across the sampled frames. ---
            var sumW = 0.0, sumX = 0.0, sumY = 0.0
            for time in sampleTimes(in: sourceRange) {
                guard let cgImage = try? await generator.image(at: time).image else { continue }

                // Image is already upright (preferred transform applied) → orientation .up.
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
                let faceRequest = VNDetectFaceRectanglesRequest()
                let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
                do {
                    try handler.perform([faceRequest, saliencyRequest])
                } catch {
                    continue   // one bad frame must not sink the whole analysis
                }

                // Faces dominate: weight 3 each. boundingBox is normalized, lower-left origin.
                for face in faceRequest.results ?? [] {
                    let box = face.boundingBox
                    let w = 3.0
                    sumW += w
                    sumX += w * Double(box.midX)
                    sumY += w * Double(box.midY)
                }

                // Salient objects: weight == confidence, ignore weak boxes.
                if let saliency = saliencyRequest.results?.first as? VNSaliencyImageObservation,
                   let objects = saliency.salientObjects {
                    for object in objects {
                        let confidence = Double(object.confidence)
                        guard confidence >= 0.15 else { continue }
                        let box = object.boundingBox
                        sumW += confidence
                        sumX += confidence * Double(box.midX)
                        sumY += confidence * Double(box.midY)
                    }
                }
            }

            // No faces and only sub-threshold saliency (or black/odd frames) → no signal.
            guard sumW >= 0.2 else { return nil }

            // Weighted interest center, still Vision normalized (lower-left origin).
            let centerX = sumX / sumW          // 0 = left,   1 = right
            let centerY = sumY / sumW          // 0 = bottom, 1 = top

            // --- Space 2: convert to displayed-image normalized, TOP-LEFT origin. ---
            // u grows left→right (unchanged); v grows top→bottom (flip Vision's y-up).
            let u = CGFloat(centerX)
            let v = CGFloat(1.0 - centerY)

            // --- Space 3: choose the render-space pan that maps (u,v) of the displayed
            // content to the render-frame center. In the content rect (size Wc×Hc, top-left
            // at the current centered position), the point (u,v) sits at offset
            // (u·Wc, v·Hc) from the content's top-left. To bring it to the content's own
            // center we shift by (0.5−u)·Wc, (0.5−v)·Hc; `panned` clamps that to the overflow
            // so the source still covers the frame. ---
            guard let centered = centeredFill(
                naturalSize: naturalSize, preferredTransform: preferredTransform, renderSize: renderSize
            ) else { return nil }
            let dx = metrics.contentSize.width * (0.5 - u)
            let dy = metrics.contentSize.height * (0.5 - v)
            return panned(centered, dx: dx, dy: dy, metrics: metrics)
        } catch {
            return nil   // any failure → caller falls back to centered fill
        }
    }

    // MARK: - Helpers

    /// The plain centered aspect-fill transform. Wrapped so a degenerate (0-size) input
    /// yields `nil` rather than an identity/garbage transform.
    private static func centeredFill(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform? {
        guard naturalSize.width > 0, naturalSize.height > 0,
              renderSize.width > 0, renderSize.height > 0 else { return nil }
        return CompositionBuilder.aspectFillTransform(
            naturalSize: naturalSize, preferredTransform: preferredTransform, renderSize: renderSize
        )
    }

    /// Start / middle / end of the source window (inset off the exact ends so tolerance-
    /// snapping stays inside the clip). A zero-/tiny-duration range (photos) → one frame.
    private static func sampleTimes(in range: CMTimeRange) -> [CMTime] {
        let start = range.start.isValid ? max(0, range.start.seconds) : 0
        let duration = range.duration.isValid ? max(0, range.duration.seconds) : 0
        guard duration > 0.05 else {
            return [CMTime(seconds: start, preferredTimescale: 600)]
        }
        return [0.05, 0.5, 0.95].map {
            CMTime(seconds: start + duration * $0, preferredTimescale: 600)
        }
    }
}
