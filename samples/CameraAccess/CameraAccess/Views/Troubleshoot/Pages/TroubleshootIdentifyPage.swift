import SwiftUI

/// First page of the Troubleshoot lens flow. Prompts the user to name or
/// show the device they're having trouble with. No interactive elements;
/// the audio meter at top shows the mic is hot.
///
/// Active when `viewModel.phase == .discovering` and there's no
/// `identifiedProduct` yet. Once Gemini calls `identify_product`, the
/// `TroubleshootConfirmOverlay` recedes the lens and asks for confirmation.
///
/// Layout mirrors coaching: live indicator top → main card middle → in-
/// lens 3-segment progress bar at bottom.
struct TroubleshootIdentifyPage: RayBanHUDView {
  @ObservedObject var viewModel: DiagnosticSessionViewModel
  /// Focus-engine `.dismiss` (lens double-tap, future MediaPipe back) →
  /// trigger the end-diagnostic confirmation alert. Owned by
  /// `TroubleshootSessionView`.
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Spacer(minLength: 0)
      audioPill
      TroubleshootStageHeaderCard(
        stage: .identify,
        title: "Show me what's broken",
        bodyText: "Or describe it out loud — say or show the device."
      )
      DiagnosticPhaseLensBar(phase: viewModel.phase)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, RayBanHUDLayoutTokens.contentPadding)
    // Passive page — no interactive elements, but `.dismiss` is
    // consumed so touch double-tap and pinch-back behave consistently
    // with the rest of the focus-engine pipeline.
    .hudInputHandler { coord in
      TroubleshootPageHandler(coordinator: coord, onDismiss: onDismiss)
    }
  }

  /// Compact audio meter wrapped in a glass capsule, sized to the bars
  /// + horizontal padding. Sits right above the main card so the user's
  /// eye finds the AI's voice activity at a glance. Mirrors coaching.
  private var audioPill: some View {
    HStack {
      Spacer(minLength: 0)
      RetraceAudioMeter(
        aiPeak: viewModel.aiOutputPeak,
        userPeak: viewModel.userInputPeak,
        tint: .white,
        intensity: .compact
      )
      .accessibilityHidden(true)
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .rayBanHUDPanel(shape: .capsule)
      Spacer(minLength: 0)
    }
  }
}
