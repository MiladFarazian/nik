import SwiftUI

/// Full-screen vertical pager over templates with a pinned "Use template" CTA.
struct TemplatePagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Entitlements.self) private var entitlements
    @Environment(PersonalizationStore.self) private var personalization

    let templates: [Template]
    let initial: Template
    let onUseTemplate: (Template) -> Void

    @State private var selection: String?
    @State private var showPaywall = false

    var body: some View {
        // Native vertical paging (iOS 17). The old rotationEffect(90°)+UIScreen.bounds
        // TabView trick rendered letterboxed/offset on iOS 26 — never again.
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(templates) { template in
                    page(for: template)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(template.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $selection)
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear { if selection == nil { selection = initial.id } }
        .onChange(of: selection) { _, newID in
            // Record a view each time a template's page becomes the active one. This
            // fires for the initial page too (selection goes nil -> initial.id on appear)
            // and for every subsequent swipe, so each is counted exactly once.
            if let newID, let template = templates.first(where: { $0.id == newID }) {
                personalization.recordView(template)
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 8)
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    private func page(for template: Template) -> some View {
        ZStack(alignment: .bottom) {
            TemplatePreviewVideo(template: template)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(template.name)
                            .font(.system(size: 17, weight: .semibold))
                        if template.isPro {
                            Text("PRO")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.proBadge, in: Capsule())
                        }
                    }
                    Text("@\(template.author)")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                    if let trend = template.trend {
                        VStack(alignment: .leading, spacing: 2) {
                            if let source = trend.source {
                                Label(source, systemImage: "chart.line.uptrend.xyaxis")
                                    .font(.footnote)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(2)
                            }
                            if let caption = trend.exampleCaption {
                                Text("\u{201C}\(caption)\u{201D}")
                                    .font(.footnote)
                                    .italic()
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(2)
                            }
                        }
                        .padding(.top, 2)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle")
                        Text("\(template.clipCount) clips · \(template.durationLabel)")
                        if let music = template.music {
                            Image(systemName: "music.note")
                            Text(music.name)
                        }
                    }
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                }
                .foregroundStyle(.white)

                Button {
                    Haptics.medium()
                    if template.isPro && !entitlements.isPro {
                        showPaywall = true
                    } else {
                        onUseTemplate(template)
                    }
                } label: {
                    Text("Use template")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
        }
    }
}
