import SwiftUI

/// Second page of the Troubleshoot lens flow. Active when phase has
/// advanced to `.diagnosing` (server gate confirmed). Shows the
/// confirmed product as a yellow chip, the phase indicator, the diagnose
/// stage card asking the user to describe symptoms, and bottom audio
/// controls.
///
/// Layout: product chip -> phase indicator -> main card -> bottom audio row.
struct TroubleshootDiagnosePage: RayBanHUDView {
  @ObservedObject var viewModel: DiagnosticSessionViewModel
  /// Focus-engine `.dismiss` → trigger the end-diagnostic confirmation
  /// alert. Owned by `TroubleshootSessionView`.
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Spacer(minLength: 0)

      productChip
      DiagnosticPhaseLensBar(phase: viewModel.phase)
      TroubleshootStageHeaderCard(
        stage: .diagnose,
        title: "Describe what's wrong",
        bodyText: "Tell me what you're seeing — strange noises, error lights, parts that don't fit."
      )
      bottomActionRow

      Spacer(minLength: 0)
    }
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, RayBanHUDLayoutTokens.contentPadding)
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

  private var productChip: some View {
    let name = (viewModel.identifiedProduct?.productName ?? "Device")
    return Text(truncate(name, max: 28).uppercased())
      .font(.inter(.bold, size: 10))
      .tracking(1.2)
      .foregroundStyle(Color.black.opacity(0.85))
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(
        Capsule().fill(Color(red: 1.0, green: 0.76, blue: 0.11))
      )
  }

  private func truncate(_ s: String, max: Int) -> String {
    s.count <= max ? s : String(s.prefix(max - 1)) + "…"
  }
}
