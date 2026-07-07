import Foundation
import AVFoundation
import UIKit

/// Runs export jobs: resolve media → build full-res composition → burn overlays →
/// AVAssetExportSession → MP4 in the project sandbox.
@Observable
final class ExportService {
    enum Phase: Equatable {
        case idle
        case preparing        // copying media / building composition
        case exporting(Double)
        case done(URL)
        case failed(String)
    }

    var phase: Phase = .idle
    private var session: AVAssetExportSession?
    private var progressTimer: Timer?

    @MainActor
    func export(project: EditProject, template: Template) async {
        phase = .preparing
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        var stage = "resolve"
        do {
            let resolver = MediaResolver()
            let resolved = try await resolver.resolve(project: project, template: template)
            let renderSize = project.exportSettings.resolution.size
            stage = "build"

            // Overlays (text, captions, watermark) are burned in by the custom
            // NikCompositor via Core Image — works identically on simulator and device.
            let built = try await CompositionBuilder.build(
                project: project,
                template: template,
                resolved: resolved,
                renderSize: renderSize,
                burnOverlays: true
            )

            #if DEBUG
            stage = "validate"
            let validator = CompositionValidator()
            let valid = try await built.videoComposition.isValid(
                for: built.composition,
                timeRange: CMTimeRange(start: .zero, duration: built.duration),
                validationDelegate: validator
            )
            if !valid || !validator.issues.isEmpty {
                stage = "validate[\(validator.issues.joined(separator: " | "))]"
                throw MediaError.exportFailed
            }
            #endif
            stage = "export"

            let outputDir = ProjectStore.mediaDirectory(for: project.id).deletingLastPathComponent()
            let outputURL = outputDir.appendingPathComponent("export-\(Int(Date().timeIntervalSince1970)).mp4")

            let preset = renderSize.width >= 2160
                ? AVAssetExportPresetHighestQuality
                : AVAssetExportPreset1920x1080
            guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {
                throw MediaError.exportFailed
            }
            session.outputURL = outputURL
            session.outputFileType = .mp4
            session.videoComposition = built.videoComposition
            session.audioMix = built.audioMix
            session.shouldOptimizeForNetworkUse = true
            self.session = session

            phase = .exporting(0)
            startProgressPolling()
            await session.export()
            stopProgressPolling()

            switch session.status {
            case .completed:
                phase = .done(outputURL)
                Haptics.success()
            case .cancelled:
                phase = .idle
            default:
                throw session.error ?? MediaError.exportFailed
            }
        } catch {
            stopProgressPolling()
            #if DEBUG
            let ns = error as NSError
            phase = .failed("[\(stage)/\(CompositionBuilder.lastStep)] \(ns.domain) \(ns.code): \(error.localizedDescription)")
            #else
            phase = .failed(error.localizedDescription)
            #endif
            Haptics.error()
        }
    }

    func cancel() {
        session?.cancelExport()
        stopProgressPolling()
        phase = .idle
    }

    private func startProgressPolling() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, let session = self.session else { return }
            if case .exporting = self.phase {
                self.phase = .exporting(Double(session.progress))
            }
        }
    }

    private func stopProgressPolling() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}

#if DEBUG
/// Collects AVVideoComposition validation failures for diagnostics.
final class CompositionValidator: NSObject, AVVideoCompositionValidationHandling {
    var issues: [String] = []

    func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool {
        issues.append("invalid value for key \(key)"); return true
    }
    func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange) -> Bool {
        issues.append(String(format: "empty time range %.3f-%.3f", timeRange.start.seconds, timeRange.end.seconds)); return true
    }
    func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTimeRangeIn instruction: AVVideoCompositionInstructionProtocol) -> Bool {
        issues.append(String(format: "invalid instruction range %.3f-%.3f", instruction.timeRange.start.seconds, instruction.timeRange.end.seconds)); return true
    }
    func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTrackIDIn instruction: AVVideoCompositionInstructionProtocol, layerInstruction: AVVideoCompositionLayerInstruction, asset: AVAsset) -> Bool {
        issues.append("invalid trackID in instruction"); return true
    }
}
#endif
