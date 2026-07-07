import SwiftUI
import Photos
import UIKit

/// Export settings → render progress → share. Full-res rebuild happens here;
/// the watermark toggle is the primary paywall trigger.
struct ExportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var projectStore
    @Environment(Entitlements.self) private var entitlements

    @State var project: EditProject
    let template: Template

    @State private var exporter = ExportService()
    @State private var showPaywall = false
    @State private var savedToPhotos = false

    var body: some View {
        NavigationStack {
            content
                .background(Theme.background)
                .navigationTitle("Export")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            exporter.cancel()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
                .sheet(isPresented: $showPaywall) { PaywallView() }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch exporter.phase {
        case .idle, .failed:
            settingsForm
        case .preparing, .exporting:
            progressView
        case .done(let url):
            ShareScreen(url: url, template: template, savedToPhotos: $savedToPhotos, onCreateAnother: { dismiss() })
        }
    }

    // MARK: - Settings

    private var settingsForm: some View {
        VStack(spacing: 16) {
            if case .failed(let message) = exporter.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
            }

            Form {
                Section("Quality") {
                    Picker("Resolution", selection: $project.exportSettings.resolution) {
                        ForEach(ExportSettings.Resolution.allCases) { res in
                            HStack {
                                Text(res.rawValue)
                                if res.isPro { Text("PRO").font(.system(size: 9, weight: .heavy)) }
                            }.tag(res)
                        }
                    }
                    .onChange(of: project.exportSettings.resolution) { _, newValue in
                        if newValue.isPro && !entitlements.isPro {
                            project.exportSettings.resolution = .p1080
                            showPaywall = true
                        }
                    }
                }
                Section {
                    Toggle("Watermark", isOn: Binding(
                        get: { project.exportSettings.watermark },
                        set: { newValue in
                            if !newValue && !entitlements.isPro {
                                showPaywall = true
                            } else {
                                project.exportSettings.watermark = newValue
                            }
                        }
                    ))
                } footer: {
                    Text(entitlements.isPro
                         ? "Pro: export watermark-free."
                         : "Go Pro to remove the watermark.")
                }
            }
            .scrollContentBackground(.hidden)

            Button {
                Haptics.medium()
                projectStore.save(project)
                Task { await exporter.export(project: project, template: template) }
            } label: {
                Text("Export video")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Progress

    private var progressView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progressValue)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.15), value: progressValue)
                Text("\(Int(progressValue * 100))%")
                    .font(.system(size: 28, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(width: 140, height: 140)

            Text(phaseLabel)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Keep nik open while exporting")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary.opacity(0.7))

            Button("Cancel") { exporter.cancel() }
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
    }

    private var progressValue: Double {
        if case .exporting(let progress) = exporter.phase { return progress }
        return 0.02
    }

    private var phaseLabel: String {
        if case .preparing = exporter.phase { return "Preparing your clips…" }
        return "Rendering \(project.exportSettings.resolution.rawValue) video…"
    }
}

// MARK: - Share screen

private struct ShareScreen: View {
    let url: URL
    let template: Template
    @Binding var savedToPhotos: Bool
    let onCreateAnother: () -> Void

    @State private var caption: String = ""
    @State private var copiedCaption = false
    @State private var copyNote: String?
    @State private var noteTask: Task<Void, Never>?

    /// Instagram's sticker-share pasteboard route only accepts videos under ~50MB;
    /// past that it silently fails, so we fall back to the camera/share-sheet route.
    private static let maxReelsVideoBytes = 50 * 1024 * 1024

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 12)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.accent)
                Text(savedToPhotos ? "Saved to your camera roll ✓" : "Your video is ready")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)

                captionComposer

                HStack(spacing: 18) {
                    shareTarget("Instagram", icon: "camera.circle.fill", action: tapInstagram)
                    shareTarget("TikTok", icon: "music.note.tv.fill", action: tapTikTok)
                    shareTarget("YouTube", icon: "play.rectangle.fill", action: tapYouTube)
                }
                .padding(.top, 6)

                noteBanner

                Text("Your video is in your camera roll — pick it inside the app to post, or use Share below.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal)

                Button("Create another", action: onCreateAnother)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minHeight: 44)

                Spacer(minLength: 16)
            }
        }
        .task {
            guard !savedToPhotos else { return }
            if (try? await PhotoLibrary.saveToPhotos(videoURL: url)) != nil {
                savedToPhotos = true
            }
        }
    }

    // MARK: Caption composer

    private var hashtags: [String] {
        switch template.category {
        case .forYou: return ["#fyp", "#foryou", "#viral"]
        case .trending: return ["#trending", "#viral", "#fyp", "#explore"]
        case .vlog: return ["#vlog", "#dailyvlog", "#lifestyle", "#fyp"]
        case .travel: return ["#travel", "#travelvlog", "#wanderlust", "#explore"]
        case .photoDump: return ["#photodump", "#memories", "#aesthetic", "#fyp"]
        case .business: return ["#smallbusiness", "#entrepreneur", "#businesstips"]
        case .velocity: return ["#velocity", "#edit", "#fyp", "#viral"]
        case .memes: return ["#meme", "#funny", "#fyp", "#viral"]
        }
    }

    private var captionComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Caption")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(caption.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }

            TextField("Write a caption…", text: $caption, axis: .vertical)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(Theme.accent)
                .lineLimit(3...6)
                .padding(12)
                .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 12))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(hashtags, id: \.self) { tag in
                        Button {
                            appendHashtag(tag)
                        } label: {
                            Text(tag)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .frame(height: 44)
                                .background(Theme.surface2, in: Capsule())
                        }
                    }
                }
            }

            Button(action: copyCaption) {
                Label(copiedCaption ? "Copied" : "Copy caption",
                      systemImage: copiedCaption ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(copiedCaption ? Theme.accent : .white)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var noteBanner: some View {
        if let copyNote {
            Text(copyNote)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.surface2, in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func appendHashtag(_ tag: String) {
        Haptics.selection()
        guard !caption.contains(tag) else { return }
        if caption.isEmpty || caption.hasSuffix(" ") {
            caption += tag
        } else {
            caption += " \(tag)"
        }
    }

    /// Explicit "Copy caption" tap — always copies (even if empty) and shows a checkmark.
    private func copyCaption() {
        UIPasteboard.general.string = caption
        Haptics.light()
        withAnimation(.easeOut(duration: 0.15)) { copiedCaption = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeOut(duration: 0.15)) { copiedCaption = false }
        }
    }

    /// Auto-copy before handing off to a platform. Skipped when there's nothing to copy.
    private func copyCaptionAndNotify() {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIPasteboard.general.string = caption
        Haptics.light()
        showNote("Caption copied — paste it when posting")
    }

    private func showNote(_ text: String) {
        noteTask?.cancel()
        withAnimation { copyNote = text }
        noteTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled {
                withAnimation { copyNote = nil }
            }
        }
    }

    // MARK: Platform targets

    private func shareTarget(_ name: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    private func tapInstagram() {
        copyCaptionAndNotify()
        openInstagram()
    }

    private func tapTikTok() {
        copyCaptionAndNotify()
        if let tiktokURL = URL(string: "tiktok://"), UIApplication.shared.canOpenURL(tiktokURL) {
            UIApplication.shared.open(tiktokURL)
        } else {
            presentShareSheet()
        }
    }

    private func tapYouTube() {
        copyCaptionAndNotify()
        openApp(urlString: "youtube://")
    }

    /// Instagram Reels route: FacebookAppID present + instagram-reels:// reachable →
    /// pasteboard sticker share. Falls back to instagram://camera, then the share sheet.
    private func openInstagram() {
        guard let appID = facebookAppID, canOpenInstagramReels else {
            openInstagramCameraOrShareSheet()
            return
        }
        Task {
            let data = try? Data(contentsOf: url)
            await MainActor.run {
                if let data, data.count < Self.maxReelsVideoBytes {
                    UIPasteboard.general.setItems(
                        [["com.instagram.sharedSticker.backgroundVideo": data]],
                        options: [.expirationDate: Date().addingTimeInterval(300)]
                    )
                    if let reelsURL = URL(string: "instagram-reels://share?source_application=\(appID)") {
                        UIApplication.shared.open(reelsURL)
                        return
                    }
                }
                openInstagramCameraOrShareSheet()
            }
        }
    }

    private func openInstagramCameraOrShareSheet() {
        if let cameraURL = URL(string: "instagram://camera"), UIApplication.shared.canOpenURL(cameraURL) {
            UIApplication.shared.open(cameraURL)
        } else {
            presentShareSheet()
        }
    }

    private var canOpenInstagramReels: Bool {
        guard let reelsURL = URL(string: "instagram-reels://share") else { return false }
        return UIApplication.shared.canOpenURL(reelsURL)
    }

    /// The placeholder value ships in Info.plist until a real Facebook App ID is configured;
    /// treat it as "absent" so the Reels pasteboard route is skipped until then.
    private var facebookAppID: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "FacebookAppID") as? String,
              !id.isEmpty, id != "REPLACE_WITH_FB_APP_ID" else { return nil }
        return id
    }

    private func presentShareSheet() {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
    }

    private func openApp(urlString: String) {
        guard let appURL = URL(string: urlString) else { return }
        UIApplication.shared.open(appURL)
    }
}
