import SwiftUI

/// Landing tab: category chips + 2-column grid of template cards.
/// Tapping a card opens the full-screen pager (TikTok-style preview).
struct TemplateFeedView: View {
    @Environment(TemplateStore.self) private var store
    @Environment(PersonalizationStore.self) private var personalization
    @Environment(DeepLinkRouter.self) private var deepLinks
    @State private var selectedCategory: TemplateCategory = .forYou
    @State private var pagerSelection: Template?
    @State private var path = NavigationPath()

    /// "For You" is personalized (adaptive ranking); every other chip keeps its
    /// category filter but surfaces the strongest/most-used templates first.
    private var filtered: [Template] {
        if selectedCategory == .forYou {
            return personalization.ranked(store.templates)
        }
        return store.templates(in: selectedCategory).sorted { lhs, rhs in
            let lt = lhs.trend?.score ?? 0, rt = rhs.trend?.score ?? 0
            if lt != rt { return lt > rt }
            return lhs.usageCount > rhs.usageCount
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 12) {
                    categoryChips
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(filtered) { template in
                            TemplateCard(template: template)
                                .onTapGesture {
                                    Haptics.selection()
                                    pagerSelection = template
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.top, 4)
                .padding(.bottom, 24)   // clear the floating tab bar
            }
            .background(Theme.background)
            .navigationTitle("nik")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $pagerSelection) { template in
                TemplatePagerView(
                    templates: filtered,
                    initial: template,
                    onUseTemplate: { chosen in
                        pagerSelection = nil
                        path.append(ClipFillRoute(template: chosen))
                    }
                )
            }
            .navigationDestination(for: ClipFillRoute.self) { route in
                ClipFillView(template: route.template, path: $path)
            }
            .navigationDestination(for: EditorRoute.self) { route in
                EditorView(projectID: route.projectID, path: $path)
            }
            .onChange(of: deepLinks.pendingTemplateID) { _, id in
                openDeepLink(id)
            }
            .onAppear { openDeepLink(deepLinks.pendingTemplateID) }
        }
    }

    /// nik://template/<id> → open that template's pager page. Switch to
    /// "For You" first: the pager pages over `filtered`, and only For You is
    /// guaranteed to contain every template.
    private func openDeepLink(_ id: String?) {
        guard let id, let template = store.template(id: id) else { return }
        deepLinks.pendingTemplateID = nil
        selectedCategory = .forYou
        pagerSelection = template
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TemplateCategory.allCases) { category in
                    let selected = category == selectedCategory
                    Text(category.rawValue)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(selected ? .black : Theme.textPrimary.opacity(0.9))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(selected ? Color.white : Color.white.opacity(0.12))
                        .clipShape(Capsule())
                        .onTapGesture {
                            Haptics.selection()
                            withAnimation(.snappy) { selectedCategory = category }
                        }
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

/// Grid card: animated gradient placeholder preview + name, usage, duration, clip count.
struct TemplateCard: View {
    let template: Template

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                Group {
                    if let poster = TemplatePreviewVideo.poster(for: template) {
                        Image(uiImage: poster)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        AnimatedTemplatePreview(template: template)
                    }
                }
                .aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack {
                    Label(template.usageLabel, systemImage: "play.fill")
                    Spacer()
                    Text("\(template.clipCount) clips · \(template.durationLabel)")
                }
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                if template.isPro {
                    Text("PRO")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.proBadge)
                        .clipShape(Capsule())
                        .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if (template.trend?.score ?? 0) >= 70 {
                    Label("Trending", systemImage: "flame.fill")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.accentGradient)
                        .clipShape(Capsule())
                        .padding(6)
                }
            }

            Text(template.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
    }
}

/// Placeholder for real template preview videos: an animated mesh-ish gradient
/// with the template's text hook, so the feed feels alive without bundled media.
struct AnimatedTemplatePreview: View {
    let template: Template
    @State private var animate = false

    var body: some View {
        let colors = template.previewColors.map { Color(hexString: $0) }
        ZStack {
            LinearGradient(
                colors: colors,
                startPoint: animate ? .topLeading : .bottomLeading,
                endPoint: animate ? .bottomTrailing : .topTrailing
            )
            .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: animate)

            VStack(spacing: 8) {
                if let hook = template.textLayers.first?.text {
                    Text(hook)
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .onAppear { animate = true }
    }
}
