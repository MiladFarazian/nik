import Foundation
import AVFoundation
import CoreGraphics

/// The single source of truth for turning (template + fills) into AVFoundation
/// objects. The same builder output drives preview (AVPlayer) and export
/// (AVAssetExportSession) — preview at reduced renderSize, export at full.
///
/// v2: renders through the custom `NikCompositor` (Core Image) using an A/B-roll
/// composition (two alternating video tracks). Transitions, filters and overlays
/// are expressed as immutable `NikInstruction` snapshots.
struct BuiltComposition {
    let composition: AVComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVAudioMix?
    let duration: CMTime
}

enum CompositionBuilder {
    /// Debug breadcrumb: last step attempted inside build(), surfaced in error banners.
    nonisolated(unsafe) static var lastStep = ""
    static let timescale: CMTimeScale = 600
    static let dipFadeDuration = 0.22       // dip-to-black fallback when a crossfade can't overlap
    static let crossfadeOverlap = 0.35      // A/B-roll overlap when the outgoing clip has spare media

    /// Per-slot facts gathered in the first pass (before any insertion).
    private struct SlotInfo {
        let slot: TemplateSlot
        let media: MediaResolver.ResolvedSlot
        let fill: SlotFill?
        /// Strong reference to the source asset. AVAssetTrack only weakly references
        /// its parent asset — without this, the asset deallocates between the gather
        /// pass and the insertion pass and insertTimeRange fails with -11800/-12780.
        let asset: AVURLAsset
        let sourceTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        let naturalSize: CGSize
        let assetDuration: CMTime
        let baseTransform: CGAffineTransform
        var startSource: CMTime          // where in the source the slot window begins
        var baseSourceDuration: CMTime   // min(wantedSource, available) — the slot window's source
        var available: CMTime            // source remaining from startSource to end
        var slotDuration: CMTime
        var speed: Double
        var outputStart: CMTime          // start of this slot on the output timeline
    }

    static func build(
        project: EditProject,
        template: Template,
        resolved: [Int: MediaResolver.ResolvedSlot],
        renderSize: CGSize,
        burnOverlays: Bool = false
    ) async throws -> BuiltComposition {
        let composition = AVMutableComposition()
        guard
            let trackA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let trackB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaError.exportFailed }
        let videoTracks = [trackA, trackB]

        // MARK: First pass — gather per-slot facts and the output timeline.
        var infos: [SlotInfo] = []
        var cursor = CMTime.zero
        for slot in template.slots {
            guard let media = resolved[slot.id] else { throw MediaError.missingFill }
            let fill = project.fills.first(where: { $0.id == slot.id })

            let asset = AVURLAsset(url: media.url)
            lastStep = "load-duration-\(slot.id)"
            let assetDuration = try await asset.load(.duration)
            lastStep = "load-videotracks-\(slot.id)"
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw MediaError.assetUnavailable
            }
            lastStep = "load-props-\(slot.id)"
            let naturalSize = try await sourceTrack.load(.naturalSize)
            let preferredTransform = try await sourceTrack.load(.preferredTransform)
            lastStep = "load-audiotracks-\(slot.id)"
            let audioTrackSource = try await asset.loadTracks(withMediaType: .audio).first
            lastStep = "gathered-\(slot.id)"

            let slotDuration = t(slot.duration)
            let wantedSource = t(slot.duration * slot.speed)
            let trimStart = t(fill?.trimStart ?? 0)
            let startSource = CMTimeMinimum(trimStart, CMTimeMaximum(.zero, assetDuration - wantedSource))
            let available = assetDuration - startSource
            let baseSourceDuration = CMTimeMinimum(wantedSource, available)

            let transform = aspectFillTransform(
                naturalSize: naturalSize, preferredTransform: preferredTransform, renderSize: renderSize
            )

            infos.append(SlotInfo(
                slot: slot, media: media, fill: fill,
                asset: asset,
                sourceTrack: sourceTrack, audioTrack: audioTrackSource,
                naturalSize: naturalSize, assetDuration: assetDuration,
                baseTransform: transform,
                startSource: startSource, baseSourceDuration: baseSourceDuration,
                available: available, slotDuration: slotDuration, speed: slot.speed,
                outputStart: cursor
            ))
            cursor = cursor + slotDuration
        }
        let totalDuration = cursor

        // MARK: Transition decisions per boundary.
        // A crossfade "into" slot i overlaps the outgoing slot i-1 by `overlap` when i-1
        // has enough spare source media beyond its window; otherwise it dips through black.
        let n = infos.count
        var overlapInto = [CMTime](repeating: .zero, count: n)   // overlap seconds for slot i's crossfade-in
        var crossfadeFeasible = [Bool](repeating: false, count: n)
        for i in stride(from: 1, to: n, by: 1) {
            guard infos[i].slot.transition == .crossfade else { continue }
            let ovSeconds = min(crossfadeOverlap,
                                infos[i - 1].slotDuration.seconds,
                                infos[i].slotDuration.seconds)
            let neededSource = t(ovSeconds * infos[i - 1].speed)
            let spare = infos[i - 1].available - infos[i - 1].baseSourceDuration
            if ovSeconds > 0, CMTimeCompare(spare, neededSource) >= 0 {
                crossfadeFeasible[i] = true
                overlapInto[i] = t(ovSeconds)
            }
        }
        // Does slot i extend past its window (because slot i+1 crossfades onto it)?
        func extendsOut(_ i: Int) -> CMTime { (i + 1 < n && crossfadeFeasible[i + 1]) ? overlapInto[i + 1] : .zero }
        // Does slot i dip to black on the way in / out?
        func dipsIn(_ i: Int) -> Bool { infos[i].slot.transition == .crossfade && !crossfadeFeasible[i] }
        func dipsOut(_ i: Int) -> Bool { i + 1 < n && infos[i + 1].slot.transition == .crossfade && !crossfadeFeasible[i + 1] }

        // MARK: Insertion pass.
        for (i, info) in infos.enumerated() {
            let videoTrack = videoTracks[i % 2]
            // Pad the (alternating) track with an empty edit so this slot lands exactly
            // at its output start rather than appended after the previous same-track slot.
            let existing = videoTrack.timeRange
            let currentEnd = (existing.start.isValid && existing.duration.isValid) ? existing.end : .zero
            if CMTimeCompare(currentEnd, info.outputStart) < 0 {
                videoTrack.insertEmptyTimeRange(
                    CMTimeRange(start: currentEnd, duration: info.outputStart - currentEnd)
                )
            }
            let overlap = extendsOut(i)
            let extraSource = t(overlap.seconds * info.speed)
            let insertSource = CMTimeRange(start: info.startSource, duration: info.baseSourceDuration + extraSource)
            lastStep = "insert-video-\(i)"
            try videoTrack.insertTimeRange(insertSource, of: info.sourceTrack, at: info.outputStart)
            lastStep = "inserted-video-\(i)"
            videoTrack.scaleTimeRange(
                CMTimeRange(start: info.outputStart, duration: insertSource.duration),
                toDuration: info.slotDuration + overlap
            )

            // Audio — unchanged behaviour: base window only, sequential, single track.
            let audioSource = CMTimeRange(start: info.startSource, duration: info.baseSourceDuration)
            if let audio = info.audioTrack, info.fill?.muted != true, !info.media.isFromPhoto {
                try? audioTrack.insertTimeRange(audioSource, of: audio, at: info.outputStart)
                audioTrack.scaleTimeRange(
                    CMTimeRange(start: info.outputStart, duration: audioSource.duration),
                    toDuration: info.slotDuration
                )
            } else {
                audioTrack.insertEmptyTimeRange(CMTimeRange(start: info.outputStart, duration: info.slotDuration))
            }
        }

        // MARK: Optional music bed (unchanged).
        var musicParams: AVMutableAudioMixInputParameters?
        if let musicID = project.musicAssetIdentifier,
           let musicPHAsset = PhotoLibrary.asset(withIdentifier: musicID) {
            let mediaDir = ProjectStore.mediaDirectory(for: project.id)
            if let url = try? await PhotoLibrary.exportVideo(asset: musicPHAsset, to: mediaDir) {
                let musicAsset = AVURLAsset(url: url)
                if let musicSource = try await musicAsset.loadTracks(withMediaType: .audio).first,
                   let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let musicDuration = try await musicAsset.load(.duration)
                    let range = CMTimeRange(start: .zero, duration: CMTimeMinimum(musicDuration, totalDuration))
                    try? musicTrack.insertTimeRange(range, of: musicSource, at: .zero)
                    let params = AVMutableAudioMixInputParameters(track: musicTrack)
                    params.setVolume(0.65, at: .zero)
                    musicParams = params
                }
            }
        }

        // MARK: Overlay snapshot (export only).
        var overlaySpec: OverlaySpec?
        if burnOverlays {
            overlaySpec = await OverlayBuilder.make(
                textLayers: project.textLayers,
                captions: project.captions,
                captionStyle: project.captionStyle,
                watermark: project.exportSettings.watermark,
                renderSize: renderSize
            )
        }

        // MARK: Instruction pass — tile [0, totalDuration] with NikInstructions.
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for (i, info) in infos.enumerated() {
            let trackID = videoTracks[i % 2].trackID
            let slotStart = info.outputStart
            let slotEnd = info.outputStart + info.slotDuration
            let filter = info.slot.filter ?? .none

            // Foreground ramps / fades for this slot (absolute-timed).
            var startTransform = info.baseTransform
            var endTransform = info.baseTransform
            var rampStart = slotStart
            var rampDuration = CMTime.zero
            var easing: Easing = .linear

            switch info.slot.transition {
            case .zoomIn:
                startTransform = zoomed(info.baseTransform, by: 1.10, renderSize: renderSize)
                endTransform = info.baseTransform
                rampStart = slotStart
                rampDuration = info.slotDuration
                easing = .easeOut
            case .punchIn:
                startTransform = zoomed(info.baseTransform, by: 1.18, renderSize: renderSize)
                endTransform = info.baseTransform
                rampStart = slotStart
                rampDuration = CMTimeMinimum(t(0.3), info.slotDuration)
                easing = .easeOut
            case .cut, .crossfade:
                break
            }

            var fadeIn: CMTimeRange?
            if crossfadeFeasible[i] {
                fadeIn = CMTimeRange(start: slotStart, duration: overlapInto[i])   // dissolve up over the overlap
            } else if dipsIn(i) {
                fadeIn = CMTimeRange(start: slotStart, duration: CMTimeMinimum(t(dipFadeDuration), info.slotDuration))
            }

            var fadeOut: CMTimeRange?
            if dipsOut(i) {
                let d = CMTimeMinimum(t(dipFadeDuration), info.slotDuration)
                fadeOut = CMTimeRange(start: slotEnd - d, duration: d)
            }

            let foreground = LayerSpec(
                trackID: trackID, sourceHeight: info.naturalSize.height,
                startTransform: startTransform, endTransform: endTransform,
                rampStart: rampStart, rampDuration: rampDuration, easing: easing,
                fadeIn: fadeIn, fadeOut: fadeOut, filter: filter
            )

            if crossfadeFeasible[i], i > 0 {
                // Two segments: overlap head (outgoing = slot i-1 as background) + solo body.
                let prev = infos[i - 1]
                let background = LayerSpec.fixed(
                    trackID: videoTracks[(i - 1) % 2].trackID,
                    sourceHeight: prev.naturalSize.height,
                    transform: prev.baseTransform,
                    filter: prev.slot.filter ?? .none
                )
                let headEnd = slotStart + overlapInto[i]
                instructions.append(NikInstruction(
                    timeRange: CMTimeRange(start: slotStart, duration: overlapInto[i]),
                    foreground: foreground, background: background, overlay: overlaySpec
                ))
                if CMTimeCompare(headEnd, slotEnd) < 0 {
                    instructions.append(NikInstruction(
                        timeRange: CMTimeRange(start: headEnd, duration: slotEnd - headEnd),
                        foreground: foreground, background: nil, overlay: overlaySpec
                    ))
                }
            } else {
                instructions.append(NikInstruction(
                    timeRange: CMTimeRange(start: slotStart, duration: info.slotDuration),
                    foreground: foreground, background: nil, overlay: overlaySpec
                ))
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = NikCompositor.self
        videoComposition.instructions = instructions
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        var audioMix: AVAudioMix?
        if let musicParams {
            let mix = AVMutableAudioMix()
            mix.inputParameters = [musicParams]
            audioMix = mix
        }

        return BuiltComposition(
            composition: composition.copy() as! AVComposition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            duration: totalDuration
        )
    }

    // MARK: - Helpers

    private static func t(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    /// Aspect-fill a source track (respecting its preferredTransform rotation)
    /// into the render frame, centered. Result is in AVFoundation video space
    /// (top-left origin); the compositor converts to Core Image space.
    static func aspectFillTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let displayedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let normalized = preferredTransform.concatenating(
            CGAffineTransform(translationX: -displayedRect.minX, y: -displayedRect.minY)
        )
        let displayedSize = CGSize(width: abs(displayedRect.width), height: abs(displayedRect.height))
        guard displayedSize.width > 0, displayedSize.height > 0 else { return normalized }

        let scale = max(renderSize.width / displayedSize.width, renderSize.height / displayedSize.height)
        let scaled = normalized.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let tx = (renderSize.width - displayedSize.width * scale) / 2
        let ty = (renderSize.height - displayedSize.height * scale) / 2
        return scaled.concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    /// Extra zoom about the render frame's center, applied on top of the base fill transform.
    private static func zoomed(_ base: CGAffineTransform, by scale: CGFloat, renderSize: CGSize) -> CGAffineTransform {
        let zoom = CGAffineTransform(translationX: renderSize.width * (1 - scale) / 2,
                                     y: renderSize.height * (1 - scale) / 2)
            .scaledBy(x: scale, y: scale)
        return base.concatenating(zoom)
    }
}
