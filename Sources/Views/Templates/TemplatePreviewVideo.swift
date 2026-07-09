import SwiftUI
import AVFoundation

/// Full-bleed looping preview video for a template, when a bundled
/// previews/<id>.mp4 exists; falls back to the animated gradient placeholder.
/// Muted autoplay, TikTok-style. One player per visible pager page (LazyVStack
/// keeps only neighbors alive).
struct TemplatePreviewVideo: View {
    let template: Template

    var body: some View {
        if let url = Self.previewURL(for: template) {
            LoopingVideoView(url: url)
        } else {
            AnimatedTemplatePreview(template: template)
        }
    }

    static func previewURL(for template: Template) -> URL? {
        Bundle.main.url(forResource: template.id, withExtension: "mp4")
    }
}

private struct LoopingVideoView: View {
    let url: URL
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?

    var body: some View {
        FillPlayerLayerView(player: player)
            .onAppear {
                if looper == nil {
                    let item = AVPlayerItem(url: url)
                    looper = AVPlayerLooper(player: player, templateItem: item)
                }
                player.isMuted = true
                player.play()
            }
            .onDisappear { player.pause() }
    }
}

/// AVPlayerLayer host with aspect-fill gravity (the pager preview is full-bleed;
/// the editor's PlayerLayerView stays aspect-fit).
private struct FillPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView.PlayerContainerView {
        let view = PlayerLayerView.PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView.PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }
}
