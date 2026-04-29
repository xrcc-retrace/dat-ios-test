import SwiftUI

/// Three-stage search lens. Active when `phase == .resolving` and
/// `resolution == nil`. Content is driven by `viewModel.searchNarration`:
///
/// - `.searchingLibrary` → "Searching your library" + animated ellipsis
/// - `.libraryMissed`    → "No procedure found in your library." (held
///                         3s as a deliberate static moment)
/// - `.searchingWeb`     → "Searching online" + animated ellipsis
///
/// All three states share `TroubleshootSearchStatusView`; the page is
/// just the lens chrome (phase bar, audio row, dismiss handler).
/// Stage transitions are spring-driven; the ellipsis animation is
/// Core-Animation-only via the shared `AnimatedEllipsis` per
/// `DESIGN.md`'s no-poll rule.
struct TroubleshootSearchingPage: RayBanHUDView {
  @ObservedObject var viewModel: DiagnosticSessionViewModel
  /// Focus-engine `.dismiss` → trigger the end-diagnostic confirmation
  /// alert. Owned by `TroubleshootSessionView`.
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Spacer(minLength: 0)

      DiagnosticPhaseLensBar(phase: viewModel.phase)
      TroubleshootSearchStatusView(viewModel: viewModel)
      bottomActionRow

      Spacer(minLength: 0)
    }
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, RayBanHUDLayoutTokens.contentPadding)
    .animation(.spring(response: 0.32, dampingFraction: 0.85), value: viewModel.searchNarration)
    // Passive page — only behavior is the dismiss path.
    .hudInputHandler { coord in
      TroubleshootPageHandler(
        coordinator: coord,
        onSetMuted: { muted in viewModel.setMuted(muted) },
        onDismiss: onDismiss
      )
    }
  }

  private var bottomActionRow: some View {
    RayBanHUDBottomAudioActionRow(
      isMuted: viewModel.isMuted,
      aiPeak: viewModel.aiOutputPeak,
      userPeak: viewModel.userInputPeak,
      muteControl: .diagnosticToggleMute,
      exitControl: .diagnosticExit,
      onToggleMute: { viewModel.toggleMute() },
      onExit: onDismiss
    )
  }
}
