import SwiftUI

/// One-time, single-screen interest picker shown on first launch. The user's picks
/// seed `PersonalizationStore.interests`; both actions ("Start creating" and "Skip")
/// mark onboarding complete so this never shows again.
struct InterestOnboardingView: View {
    @Environment(PersonalizationStore.self) private var personalization
    @Environment(\.dismiss) private var dismiss

    /// The vibe/interest tags the user can pick from. Order is intentional (creator
    /// staples first). These strings match the `tags` used across the catalog.
    private static let options = [
        "travel", "food", "fitness", "fashion", "beauty", "pets",
        "couples", "friends", "aesthetic", "meme", "business", "music",
        "sports", "study", "family", "nightlife", "nature", "tech",
    ]

    @State private var selected: Set<String> = []

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What do you make?")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Pick a few and we'll tune your feed. You can skip — nik learns as you go.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 24)

                ScrollView {
                    FlowLayout(spacing: 10) {
                        ForEach(Self.options, id: \.self) { tag in
                            chip(tag)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }

                VStack(spacing: 12) {
                    Button {
                        Haptics.success()
                        personalization.completeOnboarding(interests: selected)
                        dismiss()
                    } label: {
                        Text("Start creating")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 16))
                    }

                    Button {
                        personalization.skipOnboarding()
                        dismiss()
                    } label: {
                        Text("Skip")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
        }
    }

    private func chip(_ tag: String) -> some View {
        let isSelected = selected.contains(tag)
        return Text(tag)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textPrimary.opacity(0.85))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(isSelected ? Theme.accent.opacity(0.18) : Color.white.opacity(0.06),
                        in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? Theme.accent : Color.white.opacity(0.12),
                    lineWidth: isSelected ? 2 : 1
                )
            }
            .contentShape(Capsule())
            .onTapGesture {
                Haptics.selection()
                withAnimation(.snappy(duration: 0.2)) {
                    if isSelected { selected.remove(tag) } else { selected.insert(tag) }
                }
            }
    }
}

/// Left-aligned wrapping layout (chips flow onto the next line when the row is full).
/// Used by onboarding; kept generic so any views can wrap.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth - spacing)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
