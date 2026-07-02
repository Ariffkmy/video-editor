import AppKit
import SwiftUI

/// One-time card over Home offering the guided sample-project tutorial.
/// Account setup and personalization happen in onboarding before this appears.
struct WelcomeOverlay: View {
    let onDismiss: () -> Void

    @State private var startingTutorial = false

    var body: some View {
        ZStack {
            Color.black.opacity(AppTheme.Opacity.strong)
                .ignoresSafeArea()
            card
                .frame(width: 520)
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Learn the editor in 2 minutes")
                    .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Open a sample project and let the tour walk you through your first AI edit. Kawenreel is in beta — the feedback button in the editor reaches us directly.")
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Skip") { onDismiss() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button { startTutorial() } label: {
                    if startingTutorial {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            ProgressView().controlSize(.small)
                            Text("Loading…")
                        }
                    } else {
                        Text("Watch Tutorial")
                    }
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .keyboardShortcut(.defaultAction)
                .disabled(startingTutorial)
            }
            .padding(.top, AppTheme.Spacing.sm)
        }
        .padding(AppTheme.Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .shadow(AppTheme.Shadow.lg)
    }

    /// Open the first sample (downloading if needed); it auto-starts the tutorial.
    private func startTutorial() {
        startingTutorial = true
        Task {
            defer { startingTutorial = false }
            guard let sample = try? await SampleProjectService.shared.fetchSamples().first else {
                onDismiss()   // nothing to open
                return
            }
            do {
                try await AppState.shared.openSample(slug: sample.slug, startTutorial: true)
                onDismiss()
            } catch {
                // Leave the welcome up so the user can retry or skip.
            }
        }
    }
}
