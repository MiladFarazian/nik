import Foundation
import AVFoundation
import CoreGraphics

/// The single source of truth for turning (template + fills) into AVFoundation
/// objects. The same builder output drives preview (AVPlayer) and export
/// (AVAssetExportSession) — preview at reduced renderSize, export at full.
struct BuiltComposition {
    let composition: AVComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVAudioMix?
    let duration: CMTime
}

enum CompositionBuilder {
    static let timescale: CMTimeScale = 600
    static let dipFadeDuration = 0.22

    static func build(
        project: EditProject,
        template: Template,
        resolved: [Int: MediaResolver.ResolvedSlot],
        renderSize: CGSize
    ) async throws -> BuiltComposition {
        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaError.exportFailed }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero

        struct SlotPlacement {
            let slot: TemplateSlot
            let range: CMTimeRange
            let fillTransform: CGAffineTransform
        }
        var placements: [SlotPlacement] = []

        for slot in template.slots {
            guard let media = resolved[slot.id] else { throw MediaError.missingFill }
            let fill = project.fills.first(where: { $0.id == slot.id })

            let asset = AVURLAsset(url: media.url)
            let assetDuration = try await asset.load(.duration)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw MediaError.assetUnavailable
            }
            let naturalSize = try await sourceTrack.load(.naturalSize)
            let preferredTransform = try await sourceTrack.load(.preferredTransform)

            let slotDuration = CMTime(seconds: slot.duration, preferredTimescale: timescale)
            // Source seconds consumed = slot duration × speed (2x speed eats 2s of source per output second).
            let wantedSource = CMTime(seconds: slot.duration * slot.speed, preferredTimescale: timescale)
            let trimStart = CMTime(seconds: fill?.trimStart ?? 0, preferredTimescale: timescale)
            let start = CMTimeMinimum(trimStart, CMTimeMaximum(.zero, assetDuration - wantedSource))
            let available = assetDuration - start
            let sourceRange = CMTimeRange(start: start, duration: CMTimeMinimum(wantedSource, available))

            try videoTrack.insertTimeRange(sourceRange, of: sourceTrack, at: cursor)
            // Stretch/compress whatever we got to exactly the slot duration.
            videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: sourceRange.duration), toDuration: slotDuration)

            if let audioSource = try await asset.loadTracks(withMediaType: .audio).first,
               fill?.muted != true, !media.isFromPhoto {
                try? audioTrack.insertTimeRange(sourceRange, of: audioSource, at: cursor)
                audioTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: sourceRange.duration), toDuration: slotDuration)
            } else {
                audioTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: slotDuration))
            }

            let transform = aspectFillTransform(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                renderSize: renderSize
            )
            placements.append(SlotPlacement(
                slot: slot,
                range: CMTimeRange(start: cursor, duration: slotDuration),
                fillTransform: transform
            ))
            cursor = cursor + slotDuration
        }

        // Optional music bed from a user-picked asset (its audio track).
        var musicParams: AVMutableAudioMixInputParameters?
        if let musicID = project.musicAssetIdentifier,
           let musicPHAsset = PhotoLibrary.asset(withIdentifier: musicID) {
            let mediaDir = ProjectStore.mediaDirectory(for: project.id)
            if let url = try? await PhotoLibrary.exportVideo(asset: musicPHAsset, to: mediaDir) {
                let musicAsset = AVURLAsset(url: url)
                if let musicSource = try await musicAsset.loadTracks(withMediaType: .audio).first,
                   let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let musicDuration = try await musicAsset.load(.duration)
                    let range = CMTimeRange(start: .zero, duration: CMTimeMinimum(musicDuration, cursor))
                    try? musicTrack.insertTimeRange(range, of: musicSource, at: .zero)
                    let params = AVMutableAudioMixInputParameters(track: musicTrack)
                    params.setVolume(0.65, at: .zero)
                    musicParams = params
                }
            }
        }

        // Build one instruction per slot with transform + transition ramps.
        for (index, placement) in placements.enumerated() {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = placement.range
            instruction.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(placement.fillTransform, at: placement.range.start)

            applyTransition(
                placement.slot.transition,
                to: layer,
                base: placement.fillTransform,
                range: placement.range,
                renderSize: renderSize
            )

            // Dip-fade out at the end of this slot if the NEXT slot enters with a crossfade.
            if index + 1 < placements.count, placements[index + 1].slot.transition == .crossfade {
                let fade = CMTime(seconds: dipFadeDuration, preferredTimescale: timescale)
                layer.setOpacityRamp(
                    fromStartOpacity: 1, toEndOpacity: 0,
                    timeRange: CMTimeRange(start: placement.range.end - fade, duration: fade)
                )
            }
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
        }

        let videoComposition = AVMutableVideoComposition()
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
            duration: cursor
        )
    }

    // MARK: - Transforms

    /// Aspect-fill a source track (respecting its preferredTransform rotation)
    /// into the render frame, centered.
    static func aspectFillTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform {
        // Normalize the preferred transform so displayed content sits at origin.
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

    private static func applyTransition(
        _ transition: TransitionKind,
        to layer: AVMutableVideoCompositionLayerInstruction,
        base: CGAffineTransform,
        range: CMTimeRange,
        renderSize: CGSize
    ) {
        switch transition {
        case .cut:
            break
        case .crossfade:
            let fade = CMTime(seconds: dipFadeDuration, preferredTimescale: timescale)
            layer.setOpacityRamp(
                fromStartOpacity: 0, toEndOpacity: 1,
                timeRange: CMTimeRange(start: range.start, duration: fade)
            )
        case .zoomIn:
            // Slow settle from 1.10x to 1.0 across the whole slot.
            layer.setTransformRamp(
                fromStart: zoomed(base, by: 1.10, renderSize: renderSize),
                toEnd: base,
                timeRange: range
            )
        case .punchIn:
            // Fast pop: 1.18x → 1.0 in the first 0.3s, then hold.
            let pop = CMTime(seconds: min(0.3, range.duration.seconds), preferredTimescale: timescale)
            layer.setTransformRamp(
                fromStart: zoomed(base, by: 1.18, renderSize: renderSize),
                toEnd: base,
                timeRange: CMTimeRange(start: range.start, duration: pop)
            )
        }
    }
}
