import SwiftUI

/// First page of the Troubleshoot lens flow. Prompts the user to name or
/// show the device they're having trouble with. No interactive elements;
/// the audio meter at top shows the mic is hot.
///
/// Active when `viewModel.phase == .discovering` and there's no
/// `identifiedProduct` yet. Once Gemini calls `identify_product`, the
/// `TroubleshootConfirmOverlay` recedes the lens and asks for confirmation.
///
/// Layout mirrors coaching: phase indicator top -> main card middle ->
/// bottom audio row.
struct TroubleshootIdentifyPage: RayBanHUDView {
  @ObservedObject var viewModel: DiagnosticSessionViewModel
  /// Focus-engine `.dismiss` (lens double-tap, future MediaPipe back) →
  /// trigger the end-diagnostic confirmation alert. Owned by
  /// `TroubleshootSessionView`.
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      DiagnosticPhaseLensBar(phase: viewModel.phase)
      TroubleshootStageHeaderCard(
        stage: .identify,
        title: "Show me what's broken",
        bodyText: "Or describe it out loud — say or show the device."
      )
      bottomActionRow
      Spacer(minLength: 0)
    }
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, RayBanHUDLayoutTokens.contentPadding)
    // Passive page — no interactive elements, but `.dismiss` is
    // consumed so touch double-tap and pinch-back behave consistently
    // with the rest of the focus-engine pipeline.
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
