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

  var body: some View {
    VStack(spacing: 8) {
      Spacer(minLength: 0)

      DiagnosticPhaseLensBar(phase: viewModel.phase)
      TroubleshootStageHeaderCard(
        stage: .findFix,
        title: "Nothing found",
        bodyText: "Couldn't match a saved procedure or synthesize one from the web. Try uploading a manual."
      )
      uploadPill
      rediagnosePill
      bottomActionRow

      Spacer(minLength: 0)
    }
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, RayBanHUDLayoutTokens.contentPadding)
    // Focus-engine handler. `defaultFocus = .uploadManual` lands the
    // cursor on the Upload pill on appear; rediagnose is the secondary
    // path one swipe-down away.
    .hudInputHandler { coord in
      TroubleshootPageHandler(
        coordinator: coord,
        focusedControl: .uploadManual,
        voiceCommandLabel: "upload manual",
        secondaryControl: .rediagnose,
        secondaryVoiceLabel: "rediagnose",
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
    // Forward-path action — leading `square.and.arrow.up` glyph + text
    // signals "primary" (no permanent yellow outline; that was the
    // hover-ring color and competed with the focus signal). The
    // unified yellow hover ring is the only yellow visual on the
    // page. See DESIGN.md → Pills.
    HStack(spacing: 8) {
      Image(systemName: "square.and.arrow.up")
        .font(.system(size: 13, weight: .semibold))
      Text("Upload a manual")
        .font(.inter(.medium, size: 14))
    }
    .foregroundStyle(Color.white.opacity(0.96))
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .rayBanHUDPanel(shape: .capsule)
    .hoverSelectable(.uploadManual, shape: .capsule, onConfirm: {
      viewModel.showManualUploadSheet = true
    })
  }

  private var rediagnosePill: some View {
    // Secondary path — text-only at rest plus the `arrow.clockwise`
    // redo glyph. Identical to the Resolved page's rediagnose so the
    // affordance reads the same wherever it appears. Only the unified
    // hover ring lights up on focus.
    HStack(spacing: 6) {
      Image(systemName: "arrow.clockwise")
        .font(.system(size: 11, weight: .semibold))
      Text("Rediagnose")
        .font(.inter(.medium, size: 12))
    }
    .foregroundStyle(Color.white.opacity(0.7))
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
    .rayBanHUDPanel(shape: .capsule)
    .hoverSelectable(.rediagnose, shape: .capsule, onConfirm: {
      viewModel.rediagnose()
    })
  }
}
