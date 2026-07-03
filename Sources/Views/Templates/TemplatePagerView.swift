import SwiftUI

/// Full-screen vertical pager over templates with a pinned "Use template" CTA.
struct TemplatePagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Entitlements.self) private var entitlements

    let templates: [Template]
    let initial: Template
    let onUseTemplate: (Template) -> Void

    @State private var selection: String = ""
    @State private var showPaywall = false

    var body: some View {
        TabView(selection: $selection) {
            ForEach(templates) { template in
                page(for: template)
                    .tag(template.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .rotationEffect(.degrees(90))            // vertical paging trick
        .frame(width: UIScreen.main.bounds.height, height: UIScreen.main.bounds.width)
        .rotationEffect(.degrees(-90))
        .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear { selection = initial.id }
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
            AnimatedTemplatePreview(template: template)
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
