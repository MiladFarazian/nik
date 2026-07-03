import Foundation
import AVFoundation
import SwiftUI

/// Drives the editor: owns the player, rebuilds the composition when the
/// project changes, and exposes playhead time for overlay sync.
@MainActor
@Observable
final class EditorModel {
    var project: EditProject
    let template: Template
    let player = AVPlayer()

    var isBuilding = false
    var buildError: String?
    var currentTime: Double = 0
    var isPlaying = false
    var isTranscribing = false

    /// Preview renders at reduced size; export rebuilds at full resolution.
    static let previewRenderSize = CGSize(width: 540, height: 960)

    @ObservationIgnored nonisolated(unsafe) private var timeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private let deinitPlayer: AVPlayer
    private var built: BuiltComposition?
    private let projectStore: ProjectStore

    init(project: EditProject, template: Template, projectStore: ProjectStore) {
        self.project = project
        self.template = template
        self.projectStore = projectStore
        self.deinitPlayer = player

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.player.seek(to: .zero)
                self?.player.play()
            }
        }
    }

    deinit {
        if let timeObserver { deinitPlayer.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    var duration: Double { template.duration }

    func save() {
        projectStore.save(project)
    }

    func rebuild() async {
        isBuilding = true
        buildError = nil
        do {
            let resolved = try await MediaResolver().resolve(project: project, template: template)
            let built = try await CompositionBuilder.build(
                project: project,
                template: template,
                resolved: resolved,
                renderSize: Self.previewRenderSize
            )
            self.built = built
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            player.replaceCurrentItem(with: item)
            player.play()
            isPlaying = true
        } catch {
            buildError = error.localizedDescription
        }
        isBuilding = false
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Edits

    func updateFill(_ fill: SlotFill) {
        if let idx = project.fills.firstIndex(where: { $0.id == fill.id }) {
            project.fills[idx] = fill
            save()
            Task { await rebuild() }
        }
    }

    func updateTextLayer(_ layer: TextLayerSpec) {
        if let idx = project.textLayers.firstIndex(where: { $0.id == layer.id }) {
            project.textLayers[idx] = layer
        } else {
            project.textLayers.append(layer)
        }
        save()
    }

    func removeTextLayer(_ layer: TextLayerSpec) {
        project.textLayers.removeAll { $0.id == layer.id }
        save()
    }

    func generateCaptions() async {
        guard let built else { return }
        guard await TranscriptionService.requestPermission() else {
            buildError = "Speech recognition permission is needed for auto-captions."
            return
        }
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            let segments = try await TranscriptionService.transcribe(
                composition: built.composition, projectID: project.id
            )
            project.captions = segments
            if project.captionStyle == .none {
                project.captionStyle = .karaoke
            }
            save()
            Haptics.success()
        } catch {
            buildError = "Couldn't hear any speech to caption."
            Haptics.error()
        }
    }
}
