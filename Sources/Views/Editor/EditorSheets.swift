import SwiftUI
import Photos

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
                        Text("Start point — slide to choose which part of your clip fills this slot")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                        HStack {
                            Slider(value: $trimStart, in: 0...maxTrim)
                            Text(String(format: "%.1fs", trimStart))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                Text("Photo slot — shown with a subtle zoom")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }

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

    private func load() {
        guard let fill = model.project.fills.first(where: { $0.id == slot.id }) else { return }
        muted = fill.muted
        trimStart = fill.trimStart
        isVideo = fill.isVideo
        if let asset = PhotoLibrary.asset(withIdentifier: fill.assetLocalIdentifier) {
            maxTrim = max(0, asset.duration - slot.duration * slot.speed)
        }
    }

    private func commit() {
        guard var fill = model.project.fills.first(where: { $0.id == slot.id }) else { return }
        fill.muted = muted
        fill.trimStart = trimStart
        Haptics.light()
        model.updateFill(fill)
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
