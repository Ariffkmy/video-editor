import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Global style references — videos whose editing style (color, pacing, ordering)
/// the AI follows in every project. Per-project references are set from the media
/// panel ("Use as Style Reference").
struct StylePane: View {
    @Bindable private var store = StyleReferenceStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Style references")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("Videos that define your editing identity. The AI studies their color, cut tempo, and moment ordering, and follows them in every project. Project-specific references (set in the media panel) take priority.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppTheme.Spacing.lg)
                Button("Add video…") { addReference() }
                    .controlSize(.small)
            }

            if store.globalReferences.isEmpty {
                Text("No references yet. Add a finished film you're proud of.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(.vertical, AppTheme.Spacing.md)
            } else {
                VStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(store.globalReferences) { ref in
                        StyleReferenceRow(reference: ref)
                    }
                }
            }
        }
    }

    private func addReference() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Choose reference videos whose editing style the AI should follow"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                try? StyleReferenceStore.shared.addGlobal(url: url)
            }
        }
    }
}

private struct StyleReferenceRow: View {
    let reference: StyleReferenceStore.GlobalReference
    @Bindable private var store = StyleReferenceStore.shared
    @State private var thumbnail: NSImage?

    private var state: StyleReferenceStore.AnalysisState {
        store.states[reference.id] ?? .pending
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs).fill(Color.black)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                }
            }
            .frame(width: 64, height: 36)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(reference.name)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                summaryLine
            }

            Spacer(minLength: AppTheme.Spacing.lg)

            stateBadge

            Button {
                store.removeGlobal(id: reference.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.sm))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .help("Remove reference")
        }
        .padding(AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.white.opacity(AppTheme.Opacity.faint))
        )
        .task(id: reference.id) { await loadThumbnail() }
    }

    @ViewBuilder
    private var summaryLine: some View {
        if state == .done, let profile = store.globalProfile(id: reference.id) {
            HStack(spacing: AppTheme.Spacing.sm) {
                if let cuts = profile.cutStats {
                    Text("\(cuts.medianShotSec, specifier: "%.1f")s cuts")
                }
                if let music = profile.music {
                    Text("\(Int(music.bpm)) BPM")
                }
                if let moments = profile.momentSequence, !moments.isEmpty {
                    Text(moments.prefix(3).joined(separator: " → "))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
        } else {
            Text(stateDescription)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch state {
        case .analyzing:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(.yellow)
                .help(stateDescription)
        default:
            EmptyView()
        }
    }

    private var stateDescription: String {
        switch state {
        case .pending: "Waiting to analyze"
        case .analyzing: "Analyzing…"
        case .done: "Analyzed"
        case .failed(let reason): "Analysis failed: \(reason)"
        }
    }

    private func loadThumbnail() async {
        guard thumbnail == nil, let url = store.videoURL(globalId: reference.id) else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 128, height: 128)
        if let cg = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image {
            thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}
