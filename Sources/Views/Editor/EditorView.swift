import SwiftUI
import Photos

/// The template editor: live preview with synced overlays, a segment rail for
/// per-clip tweaks, text/caption tools, and the export entry point.
struct EditorView: View {
    @Environment(ProjectStore.self) private var projectStore
    @Environment(TemplateStore.self) private var templateStore
    @Environment(PhotoLibrary.self) private var library

    let projectID: UUID
    @Binding var path: NavigationPath

    @State private var model: EditorModel?
    @State private var editingText: TextLayerSpec?
    @State private var editingSlot: TemplateSlot?
    @State private var showCaptionsSheet = false
    @State private var showExport = false

    var body: some View {
        Group {
            if let model {
                editor(model: model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Export") {
                    Haptics.medium()
                    model?.player.pause()
                    showExport = true
                }
                .font(.system(size: 16, weight: .semibold))
                .disabled(model?.isBuilding ?? true)
            }
        }
        .task {
            guard model == nil else { return }
            guard
                let project = projectStore.projects.first(where: { $0.id == projectID }),
                let template = templateStore.template(id: project.templateID)
            else { return }
            let newModel = EditorModel(project: project, template: template, projectStore: projectStore)
            model = newModel
            await newModel.rebuild()
        }
        .onDisappear { model?.player.pause() }
    }

    private func editor(model: EditorModel) -> some View {
        VStack(spacing: 0) {
            previewArea(model: model)
            segmentRail(model: model)
            toolTray(model: model)
        }
        .background(Theme.background)
        .sheet(item: $editingText) { layer in
            TextEditSheet(layer: layer) { updated, delete in
                if delete { model.removeTextLayer(updated) } else { model.updateTextLayer(updated) }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $editingSlot) { slot in
            SlotEditSheet(model: model, slot: slot)
                .presentationDetents([.height(360)])
        }
        .sheet(isPresented: $showCaptionsSheet) {
            CaptionsSheet(model: model)
                .presentationDetents([.height(320)])
        }
        .fullScreenCover(isPresented: $showExport) {
            ExportView(project: model.project, template: model.template)
        }
    }

    // MARK: - Preview + overlays

    private func previewArea(model: EditorModel) -> some View {
        GeometryReader { geo in
            let videoSize = fittedVideoSize(in: geo.size)
            ZStack {
                Color.black
                ZStack {
                    PlayerLayerView(player: model.player)
                    OverlayPreview(model: model, videoSize: videoSize)
                        .allowsHitTesting(true)
                    if model.isBuilding {
                        ProgressView("Building preview…")
                            .tint(.white)
                    }
                }
                .frame(width: videoSize.width, height: videoSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture { model.togglePlayback() }
        }
        .overlay(alignment: .bottomLeading) {
            Text(timeLabel(model.currentTime) + " / " + timeLabel(model.duration))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(10)
        }
        .overlay(alignment: .bottom) {
            if let error = model.buildError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            }
        }
    }

    private func fittedVideoSize(in container: CGSize) -> CGSize {
        let aspect: CGFloat = 9.0 / 16.0
        let height = min(container.height, container.width / aspect)
        return CGSize(width: height * aspect, height: height)
    }

    private func timeLabel(_ seconds: Double) -> String {
        String(format: "0:%04.1f", max(0, seconds))
    }

    // MARK: - Segment rail

    private func segmentRail(model: EditorModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.template.slots) { slot in
                    SegmentThumb(
                        model: model,
                        slot: slot,
                        isActive: isSlotActive(slot, model: model)
                    ) {
                        Haptics.selection()
                        editingSlot = slot
                        model.player.pause()
                        model.isPlaying = false
                        model.seek(to: slotStart(slot, model: model) + 0.05)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.surface1)
    }

    private func slotStart(_ slot: TemplateSlot, model: EditorModel) -> Double {
        model.template.slots.prefix(while: { $0.id != slot.id }).reduce(0) { $0 + $1.duration }
    }

    private func isSlotActive(_ slot: TemplateSlot, model: EditorModel) -> Bool {
        let start = slotStart(slot, model: model)
        return model.currentTime >= start && model.currentTime < start + slot.duration
    }

    // MARK: - Tool tray

    private func toolTray(model: EditorModel) -> some View {
        HStack(spacing: 0) {
            trayButton("Text", icon: "textformat") {
                model.player.pause()
                model.isPlaying = false
                editingText = model.project.textLayers.first
                    ?? TextLayerSpec(text: "your text", start: 0, duration: min(2.5, model.duration))
            }
            trayButton("Captions", icon: "captions.bubble") {
                model.player.pause()
                model.isPlaying = false
                showCaptionsSheet = true
            }
            trayButton(model.isPlaying ? "Pause" : "Play", icon: model.isPlaying ? "pause.fill" : "play.fill") {
                model.togglePlayback()
            }
            trayButton("Replay", icon: "arrow.counterclockwise") {
                model.seek(to: 0)
                model.player.play()
                model.isPlaying = true
            }
        }
        .padding(.vertical, 8)
        .background(Theme.surface1)
    }

    private func trayButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Live overlay preview (mirrors OverlayLayerFactory positioning)

private struct OverlayPreview: View {
    let model: EditorModel
    let videoSize: CGSize

    var body: some View {
        let scale = videoSize.width / 1080.0
        ZStack {
            ForEach(model.project.textLayers) { spec in
                if model.currentTime >= spec.start && model.currentTime <= spec.start + spec.duration {
                    TextLayerPreview(spec: spec, scale: scale)
                        .position(x: videoSize.width / 2, y: videoSize.height * spec.relativeY)
                }
            }
            if model.project.captionStyle != .none,
               let segment = model.project.captions.first(where: {
                   model.currentTime >= $0.start && model.currentTime <= $0.start + $0.duration
               }) {
                CaptionPreview(
                    segment: segment,
                    style: model.project.captionStyle,
                    currentTime: model.currentTime,
                    width: videoSize.width
                )
                .position(x: videoSize.width / 2, y: videoSize.height * 0.78)
            }
        }
        .frame(width: videoSize.width, height: videoSize.height)
        .allowsHitTesting(false)
    }
}

struct TextLayerPreview: View {
    let spec: TextLayerSpec
    let scale: CGFloat

    var body: some View {
        let size = spec.fontSize * scale
        switch spec.style {
        case .block:
            Text(spec.text)
                .font(.system(size: size, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        case .bold:
            Text(spec.text)
                .font(.system(size: size, weight: .heavy))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 4, y: 2)
        case .outlined, .caption:
            Text(spec.text)
                .font(.system(size: size, weight: .heavy))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 1)
                .shadow(color: .black, radius: 1)
                .shadow(color: .black, radius: 2)
        }
    }
}

private struct CaptionPreview: View {
    let segment: CaptionSegment
    let style: CaptionStyle
    let currentTime: Double
    let width: CGFloat

    var body: some View {
        let fontSize = width * 0.055
        HStack(spacing: fontSize * 0.28) {
            let words = segment.words.isEmpty
                ? [CaptionWord(text: segment.text, start: segment.start, duration: segment.duration)]
                : segment.words
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                let spoken = currentTime >= word.start
                Text(word.text)
                    .font(.system(size: fontSize, weight: .heavy))
                    .foregroundStyle(style == .karaoke && spoken ? Theme.accent : .white)
                    .scaleEffect(style == .bounce && spoken && currentTime <= word.start + 0.15 ? 1.2 : 1.0)
                    .shadow(color: .black, radius: 1)
                    .shadow(color: .black, radius: 2)
            }
        }
        .padding(.horizontal, style == .block ? 12 : 0)
        .padding(.vertical, style == .block ? 6 : 0)
        .background {
            if style == .block {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.7))
            }
        }
        .animation(.snappy(duration: 0.12), value: currentTime)
    }
}

// MARK: - Segment thumb

private struct SegmentThumb: View {
    @Environment(PhotoLibrary.self) private var library
    let model: EditorModel
    let slot: TemplateSlot
    let isActive: Bool
    let onTap: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Theme.surface2
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isActive ? Theme.accent : .clear, lineWidth: 2)
            }
            .overlay(alignment: .bottomTrailing) {
                if model.project.fills.first(where: { $0.id == slot.id })?.muted == true {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.black.opacity(0.7), in: Circle())
                        .padding(2)
                }
            }

            Text(String(format: "%.1fs", slot.duration))
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
        .onTapGesture(perform: onTap)
        .task {
            guard
                let fill = model.project.fills.first(where: { $0.id == slot.id }),
                let asset = PhotoLibrary.asset(withIdentifier: fill.assetLocalIdentifier)
            else { return }
            thumbnail = await library.thumbnail(for: asset, size: CGSize(width: 96, height: 96))
        }
    }
}
