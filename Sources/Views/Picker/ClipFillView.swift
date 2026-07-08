import SwiftUI
import Photos

/// CapCut-style slot filler: media library grid on top, numbered slot tray pinned
/// at the bottom. Tapping a library item fills the highlighted slot and advances.
struct ClipFillView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(ProjectStore.self) private var projectStore

    let template: Template
    @Binding var path: NavigationPath

    @State private var fills: [Int: SlotFill] = [:]
    @State private var highlightedSlot: Int = 0
    @State private var mediaFilter: MediaFilter = .all

    enum MediaFilter: String, CaseIterable {
        case all = "All", videos = "Videos", photos = "Photos"
    }

    private var allFilled: Bool { fills.count == template.slots.count }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            libraryGrid
            slotTray
        }
        .background(Theme.background)
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await library.requestAccess() }
    }

    private var filterBar: some View {
        Picker("Media", selection: $mediaFilter) {
            ForEach(MediaFilter.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Library grid

    @ViewBuilder
    private var libraryGrid: some View {
        if library.accessState == .denied {
            ContentUnavailableView(
                "Camera roll access needed",
                systemImage: "photo.badge.exclamationmark",
                description: Text("Enable photo access in Settings to fill this template with your clips.")
            )
            .frame(maxHeight: .infinity)
        } else if let assets = library.assets {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 2) {
                    ForEach(0..<assets.count, id: \.self) { index in
                        let asset = assets.object(at: index)
                        if matchesFilter(asset) {
                            LibraryCell(asset: asset, useCount: useCount(of: asset)) {
                                fill(with: asset)
                            }
                        }
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxHeight: .infinity)
        }
    }

    private func matchesFilter(_ asset: PHAsset) -> Bool {
        switch mediaFilter {
        case .all: return true
        case .videos: return asset.mediaType == .video
        case .photos: return asset.mediaType == .image
        }
    }

    private func useCount(of asset: PHAsset) -> Int {
        fills.values.filter { $0.assetLocalIdentifier == asset.localIdentifier }.count
    }

    private func fill(with asset: PHAsset) {
        guard let slot = template.slots.first(where: { $0.id == highlightedSlot }) else { return }
        // Videos must be at least as long as the slot needs at its speed.
        if asset.mediaType == .video, asset.duration < slot.duration * slot.speed * 0.5 {
            Haptics.error()
            return
        }
        Haptics.light()
        fills[slot.id] = SlotFill(
            id: slot.id,
            assetLocalIdentifier: asset.localIdentifier,
            isVideo: asset.mediaType == .video
        )
        // Advance to the next empty slot.
        if let next = template.slots.first(where: { fills[$0.id] == nil }) {
            highlightedSlot = next.id
        }
    }

    // MARK: - Slot tray

    private var slotTray: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(template.slots) { slot in
                        SlotCell(
                            slot: slot,
                            fill: fills[slot.id],
                            isHighlighted: slot.id == highlightedSlot,
                            onTap: {
                                Haptics.selection()
                                highlightedSlot = slot.id
                            },
                            onClear: {
                                Haptics.light()
                                fills[slot.id] = nil
                                highlightedSlot = slot.id
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
            }

            Button {
                startProject()
            } label: {
                Text(allFilled ? "Preview" : "Preview (\(fills.count)/\(template.slots.count))")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        allFilled ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.15)),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
            }
            .disabled(!allFilled)
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
        .background(Theme.surface1)
    }

    private func startProject() {
        Haptics.medium()
        let ordered = template.slots.compactMap { fills[$0.id] }
        let project = EditProject(template: template, fills: ordered)
        projectStore.save(project)
        path.append(EditorRoute(projectID: project.id))
    }
}

// MARK: - Cells

private struct LibraryCell: View {
    @Environment(PhotoLibrary.self) private var library
    let asset: PHAsset
    let useCount: Int
    let onTap: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Theme.surface2
                }
                if asset.mediaType == .video {
                    Text(durationLabel)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(4)
                }
                if useCount > 0 {
                    Color.white.opacity(0.25)
                    Text("\(useCount)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Theme.accent, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .task {
            thumbnail = await library.thumbnail(
                for: asset,
                size: CGSize(width: 220, height: 220)
            )
        }
    }

    private var durationLabel: String {
        let secs = Int(asset.duration.rounded())
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}

private struct SlotCell: View {
    @Environment(PhotoLibrary.self) private var library
    let slot: TemplateSlot
    let fill: SlotFill?
    let isHighlighted: Bool
    let onTap: () -> Void
    let onClear: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isHighlighted ? Theme.accent : Color.white.opacity(0.25),
                        style: StrokeStyle(lineWidth: isHighlighted ? 2 : 1, dash: fill == nil ? [5, 4] : [])
                    )
                    .background {
                        if let thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                if fill == nil {
                    Text("\(slot.id + 1)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 56, height: 56)
            .overlay(alignment: .topTrailing) {
                if fill != nil {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, .black.opacity(0.7))
                    }
                    .offset(x: 6, y: -6)
                }
            }

            Text(String(format: "%.1fs", slot.duration))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(isHighlighted ? Theme.accent : Theme.textSecondary)
        }
        .onTapGesture(perform: onTap)
        .task(id: fill?.assetLocalIdentifier) {
            guard let fill, let asset = PhotoLibrary.asset(withIdentifier: fill.assetLocalIdentifier) else {
                thumbnail = nil
                return
            }
            thumbnail = await library.thumbnail(for: asset, size: CGSize(width: 112, height: 112))
        }
    }
}
