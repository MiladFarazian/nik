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
            ShareScreen(url: url, savedToPhotos: $savedToPhotos, onCreateAnother: { dismiss() })
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
    @Binding var savedToPhotos: Bool
    let onCreateAnother: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
            Text(savedToPhotos ? "Saved to your camera roll ✓" : "Your video is ready")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 18) {
                shareTarget("Instagram", icon: "camera.circle.fill") {
                    openApp(urlString: "instagram://camera")
                }
                shareTarget("TikTok", icon: "music.note.tv.fill") {
                    openApp(urlString: "tiktok://")
                }
                shareTarget("YouTube", icon: "play.rectangle.fill") {
                    openApp(urlString: "youtube://")
                }
            }
            .padding(.top, 6)

            Text("Your video is in your camera roll — pick it inside the app to post.")
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
            Spacer()
        }
        .task {
            guard !savedToPhotos else { return }
            if (try? await PhotoLibrary.saveToPhotos(videoURL: url)) != nil {
                savedToPhotos = true
            }
        }
    }

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
        }
    }

    private func openApp(urlString: String) {
        guard let appURL = URL(string: urlString) else { return }
        UIApplication.shared.open(appURL)
    }
}
