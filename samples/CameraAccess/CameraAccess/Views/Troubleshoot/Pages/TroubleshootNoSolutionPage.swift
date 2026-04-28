import SwiftUI

/// Terminal "we couldn't find anything" page. Active when
/// `resolution == .noMatch` (web search exhausted). The user's only path
/// forward is to upload a manual themselves; that lands in the library
/// and the user can re-run the diagnostic.
///
/// Layout mirrors coaching: phase indicator top -> main card middle ->
/// Upload pill -> bottom audio row.
struct TroubleshootNoSolutionPage: RayBanHUDView {
  @ObservedObject var viewModel: DiagnosticSessionViewModel
  /// Focus-engine `.dismiss` → trigger the end-diagnostic confirmation
  /// alert. Owned by `TroubleshootSessionView`.
  let onDismiss: () -> Void

  @EnvironmentObject private var hoverCoordinator: HUDHoverCoordinator

  var body: some View {
    VStack(spacing: 8) {
      DiagnosticPhaseLensBar(phase: viewModel.phase)
      TroubleshootStageHeaderCard(
        stage: .findFix,
        title: "Nothing found",
        bodyText: "Couldn't match a saved procedure or synthesize one from the web. Try uploading a manual."
      )
      uploadPill
      bottomActionRow
      Spacer(minLength: 0)
    }
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, RayBanHUDLayoutTokens.contentPadding)
    // Focus-engine handler. `defaultFocus = .uploadManual` lands the
    // cursor on the Upload pill on appear.
    .hudInputHandler { coord in
      TroubleshootPageHandler(
        coordinator: coord,
        focusedControl: .uploadManual,
        voiceCommandLabel: "upload manual",
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

  private var uploadPill: some View {
    let isHovered = hoverCoordinator.hovered == .uploadManual
    return Text("Upload a manual")
      .font(.inter(.medium, size: 14))
      .foregroundStyle(isHovered ? Color.black.opacity(0.88) : Color.white.opacity(0.96))
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
      .background(
        Capsule().fill(isHovered ? Color.white.opacity(0.95) : Color.clear)
      )
      .rayBanHUDPanel(shape: .capsule)
      .hoverSelectable(.uploadManual, shape: .capsule, onConfirm: {
        viewModel.showManualUploadSheet = true
      })
  }
}
