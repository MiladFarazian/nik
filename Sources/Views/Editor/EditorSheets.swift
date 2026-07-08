import SwiftUI
import Photos
import AVFoundation
import CoreGraphics

// MARK: - Text layer editing

struct TextEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var layer: TextLayerSpec
    let onCommit: (TextLayerSpec, _ delete: Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextField("Your text", text: $layer.text, axis: .vertical)
                        .font(.system(size: 17, weight: .semibold))
                }
                Section("Style") {
                    Picker("Look", selection: $layer.style) {
                        ForEach(TextLayerSpec.TextStyle.allCases, id: \.self) { style in
                            Text(label(for: style)).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Size")
                        Slider(value: $layer.fontSize, in: 36...120, step: 2)
                    }
                    HStack {
                        Text("Position")
                        Slider(value: Binding(
                            get: { Double(layer.relativeY) },
                            set: { layer.relativeY = CGFloat($0) }
                        ), in: 0.08...0.92)
                    }
                }
                Section("Timing") {
                    HStack {
                        Text("Starts at")
                        Slider(value: $layer.start, in: 0...20)
                        Text(String(format: "%.1fs", layer.start))
                            .font(.footnote.monospacedDigit())
                    }
                    HStack {
                        Text("Shows for")
                        Slider(value: $layer.duration, in: 0.5...20)
                        Text(String(format: "%.1fs", layer.duration))
                            .font(.footnote.monospacedDigit())
                    }
                }
                Section {
                    Button("Delete text", role: .destructive) {
                        onCommit(layer, true)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Edit text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onCommit(layer, false)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func label(for style: TextLayerSpec.TextStyle) -> String {
        switch style {
        case .bold: return "Bold"
        case .outlined: return "Outline"
        case .block: return "Block"
        case .caption: return "Small"
        }
    }
}

// MARK: - Per-slot editing (mute, trim start)

struct SlotEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: EditorModel
    let slot: TemplateSlot

    @State private var muted = false
    @State private var trimStart = 0.0
    @State private var maxTrim = 0.0
    @State private var isVideo = false
    @State private var assetLocalIdentifier = ""
    @State private var filmstripUnavailable = false
    @State private var isManualCrop = false
    @State private var panX = 0.0
    @State private var panY = 0.0

    var body: some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(.white.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            Text("Clip \(slot.id + 1) · \(String(format: "%.1fs", slot.duration))\(slot.speed != 1 ? " · \(String(format: "%.1fx", slot.speed))" : "")")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            if let hint = slot.hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }

            if isVideo {
                Toggle(isOn: $muted) {
                    Label("Mute clip audio", systemImage: "speaker.slash")
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.horizontal)

                if maxTrim > 0.05 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Start point — drag to choose which part of your clip fills this slot")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)

                        if filmstripUnavailable {
                            HStack {
                                Slider(value: $trimStart, in: 0...maxTrim)
                                Text(String(format: "%.1fs", trimStart))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        } else {
                            FilmstripTrimmer(
                                model: model,
                                assetLocalIdentifier: assetLocalIdentifier,
                                slotSourceDuration: slot.duration * slot.speed,
                                maxTrim: maxTrim,
                                trimStart: $trimStart,
                                onUnavailable: { filmstripUnavailable = true }
                            )
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                Text("Photo slot — shown with a subtle zoom")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }

            reframeSection

            Button {
                commit()
                dismiss()
            } label: {
                Text("Apply")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)

            Spacer(minLength: 0)
        }
        .background(Theme.surface1)
        .onAppear(perform: load)
    }

    // MARK: - Reframe (manual crop pan override)

    private var reframeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reframe")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("Reframe mode", selection: $isManualCrop) {
                    Text("Auto").tag(false)
                    Text("Manual").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: isManualCrop) { _, _ in
                    Haptics.selection()
                }
            }

            if isManualCrop {
                HStack(spacing: 10) {
                    Text("Pan X")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 46, alignment: .leading)
                    Slider(value: $panX, in: -1...1)
                }
                HStack(spacing: 10) {
                    Text("Pan Y")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 46, alignment: .leading)
                    Slider(value: $panY, in: -1...1)
                }
            }
        }
        .padding(.horizontal)
    }

    private func load() {
        guard let fill = model.project.fills.first(where: { $0.id == slot.id }) else { return }
        muted = fill.muted
        trimStart = fill.trimStart
        isVideo = fill.isVideo
        assetLocalIdentifier = fill.assetLocalIdentifier
        if let asset = PhotoLibrary.asset(withIdentifier: fill.assetLocalIdentifier) {
            maxTrim = max(0, asset.duration - slot.duration * slot.speed)
        }
        if let offset = fill.cropOffset {
            isManualCrop = true
            panX = Double(offset.x)
            panY = Double(offset.y)
        } else {
            isManualCrop = false
            panX = 0
            panY = 0
        }
    }

    private func commit() {
        guard var fill = model.project.fills.first(where: { $0.id == slot.id }) else { return }
        fill.muted = muted
        fill.trimStart = trimStart
        fill.cropOffset = isManualCrop ? CGPoint(x: panX, y: panY) : nil
        Haptics.light()
        model.updateFill(fill)
    }
}

// MARK: - CapCut-style filmstrip trimmer
//
// A fixed, centered selection window sits on top of a horizontally scrollable
// filmstrip. Dragging slides the filmstrip content; the window never moves.
// The window's width represents `slotSourceDuration` seconds of source, at
// the same px/second scale as the filmstrip itself, so the region of the
// strip under the window is always exactly the clip that will fill the slot.
private struct FilmstripTrimmer: View {
    let model: EditorModel
    let assetLocalIdentifier: String
    let slotSourceDuration: Double
    let maxTrim: Double
    @Binding var trimStart: Double
    let onUnavailable: () -> Void

    private enum LoadState { case loading, loaded, failed }

    @State private var loadState: LoadState = .loading
    @State private var thumbnails: [UIImage] = []
    @State private var assetDuration: Double = 0
    @State private var currentOffset: CGFloat = 0
    @State private var dragBaseOffset: CGFloat = 0
    @State private var wasClampedLow = false
    @State private var wasClampedHigh = false

    private let thumbWidth: CGFloat = 46
    private let thumbHeight: CGFloat = 64
    private let thumbnailCount = 10

    /// Points per second of source, derived from how densely the generated
    /// thumbnails tile across the strip. The selection window is sized in
    /// this same scale so it always spans exactly `slotSourceDuration`
    /// seconds of the underlying clip.
    private var pxPerSecond: CGFloat {
        guard assetDuration > 0, !thumbnails.isEmpty else { return 1 }
        return (thumbWidth * CGFloat(thumbnails.count)) / CGFloat(assetDuration)
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: thumbHeight)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
            case .failed:
                EmptyView()
            case .loaded:
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        let viewportWidth = geo.size.width
                        let contentWidth = thumbWidth * CGFloat(thumbnails.count)
                        let windowWidth = min(max(CGFloat(slotSourceDuration) * pxPerSecond, 28), viewportWidth)
                        let windowInset = (viewportWidth - windowWidth) / 2
                        let minOffset = -CGFloat(max(maxTrim, 0)) * pxPerSecond
                        let maxOffset: CGFloat = 0

                        ZStack(alignment: .leading) {
                            HStack(spacing: 0) {
                                ForEach(thumbnails.indices, id: \.self) { i in
                                    Image(uiImage: thumbnails[i])
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: thumbWidth, height: thumbHeight)
                                        .clipped()
                                }
                            }
                            .frame(width: contentWidth, height: thumbHeight, alignment: .leading)
                            .offset(x: windowInset + currentOffset)

                            // Dim everything outside the fixed selection window.
                            HStack(spacing: 0) {
                                Color.black.opacity(0.55).frame(width: max(windowInset, 0))
                                Color.clear.frame(width: windowWidth)
                                Color.black.opacity(0.55)
                            }
                            .allowsHitTesting(false)

                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Theme.accent, lineWidth: 3)
                                .frame(width: windowWidth, height: thumbHeight)
                                .offset(x: windowInset)
                                .allowsHitTesting(false)
                        }
                        .frame(width: viewportWidth, height: thumbHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    var newOffset = dragBaseOffset + value.translation.width
                                    let atMin = newOffset <= minOffset
                                    let atMax = newOffset >= maxOffset
                                    newOffset = min(max(newOffset, minOffset), maxOffset)

                                    if atMin {
                                        if !wasClampedLow { Haptics.selection() }
                                        wasClampedLow = true
                                    } else {
                                        wasClampedLow = false
                                    }
                                    if atMax {
                                        if !wasClampedHigh { Haptics.selection() }
                                        wasClampedHigh = true
                                    } else {
                                        wasClampedHigh = false
                                    }

                                    currentOffset = newOffset
                                    trimStart = pxPerSecond > 0 ? Double(-newOffset / pxPerSecond) : 0
                                }
                                .onEnded { _ in
                                    dragBaseOffset = currentOffset
                                }
                        )
                    }
                    .frame(height: thumbHeight)

                    Text(String(format: "%.1fs", trimStart))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .task(id: assetLocalIdentifier) {
            await loadFilmstrip()
        }
    }

    private func loadFilmstrip() async {
        loadState = .loading
        do {
            let url = try await MediaResolver.localVideoURL(
                assetLocalIdentifier: assetLocalIdentifier,
                projectID: model.project.id
            )
            if Task.isCancelled { return }

            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                loadState = .failed
                onUnavailable()
                return
            }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 800, height: 120)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

            var images: [UIImage] = []
            for i in 0..<thumbnailCount {
                if Task.isCancelled { return }
                let t = duration * (Double(i) + 0.5) / Double(thumbnailCount)
                let time = CMTime(seconds: t, preferredTimescale: 600)
                let result = try await generator.image(at: time)
                images.append(UIImage(cgImage: result.image))
            }
            if Task.isCancelled { return }

            assetDuration = duration
            thumbnails = images

            // Seed the strip's scroll offset from the fill's existing trimStart
            // so re-opening the sheet shows the previously chosen window.
            let scale = (thumbWidth * CGFloat(images.count)) / CGFloat(duration)
            let clampedTrimStart = min(max(trimStart, 0), max(maxTrim, 0))
            currentOffset = -CGFloat(clampedTrimStart) * scale
            dragBaseOffset = currentOffset
            loadState = .loaded
        } catch {
            if Task.isCancelled { return }
            loadState = .failed
            onUnavailable()
        }
    }
}

// MARK: - Captions

struct CaptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: EditorModel

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(.white.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            Text("Auto captions")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            if model.project.captions.isEmpty {
                Text("Transcribes your clips' speech on-device and burns animated captions into the export.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Button {
                    Task { await model.generateCaptions() }
                } label: {
                    HStack {
                        if model.isTranscribing {
                            ProgressView().tint(.white)
                        }
                        Text(model.isTranscribing ? "Transcribing…" : "Generate captions")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(model.isTranscribing)
                .padding(.horizontal)
            } else {
                stylePicker
                Button("Remove captions", role: .destructive) {
                    model.project.captions = []
                    model.project.captionStyle = .none
                    model.save()
                    dismiss()
                }
                .font(.footnote)
            }

            Spacer(minLength: 0)
        }
        .background(Theme.surface1)
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STYLE")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(CaptionStyle.allCases.filter { $0 != .none }) { style in
                        let selected = model.project.captionStyle == style
                        VStack(spacing: 6) {
                            Text("Aa")
                                .font(.system(size: 22, weight: .heavy))
                                .foregroundStyle(style == .karaoke ? Theme.accent : .white)
                                .frame(width: 64, height: 44)
                                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2)
                                }
                            Text(style.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        }
                        .onTapGesture {
                            Haptics.selection()
                            model.project.captionStyle = style
                            model.save()
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
