import SwiftUI

/// Resolved page — Gemini has a procedure ready (either matched from the
/// library or generated from a web search). Big card carries the
/// procedure title and source provenance; a "Start" pill below the card
/// hands off to the learner session.
///
/// Active when `viewModel.resolution` is `.matchedProcedure` or
/// `.generatedSOP`. Default focus on the Start pill so a single select
/// gesture commits to the forward path.
///
/// Layout mirrors coaching: phase indicator top -> main card middle ->
/// Start pill -> bottom audio row.
struct TroubleshootResolvedPage: RayBanHUDView {
  @ObservedObject var viewModel: DiagnosticSessionViewModel
  let onStart: (String) -> Void
  /// Focus-engine `.dismiss` → trigger the end-diagnostic confirmation
  /// alert. Owned by `TroubleshootSessionView`.
  let onDismiss: () -> Void

  @EnvironmentObject private var hoverCoordinator: HUDHoverCoordinator

  var body: some View {
    VStack(spacing: 8) {
      DiagnosticPhaseLensBar(phase: viewModel.phase)
      TroubleshootStageHeaderCard(
        stage: .findFix,
        title: procedureTitle,
        bodyText: sourceText
      )
      startPill
      bottomActionRow
      Spacer(minLength: 0)
    }
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, RayBanHUDLayoutTokens.contentPadding)
    // Focus-engine handler. `defaultFocus = .startProcedure` lands the
    // cursor on the Start pill on appear.
    .hudInputHandler { coord in
      TroubleshootPageHandler(
        coordinator: coord,
        focusedControl: .startProcedure,
        voiceCommandLabel: "start",
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

  @ViewBuilder
  private var startPill: some View {
    if viewModel.handoffInFlight {
      HStack(spacing: 8) {
        ProgressView()
          .tint(Color.white.opacity(0.7))
          .controlSize(.small)
        Text("Starting…")
          .font(.inter(.medium, size: 14))
          .foregroundStyle(Color.white.opacity(0.7))
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
      .rayBanHUDPanel(shape: .capsule)
    } else if viewModel.handoffError != nil {
      Text("Try again")
        .font(.inter(.medium, size: 14))
        .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.11))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .rayBanHUDPanel(shape: .capsule)
        .hoverSelectable(.startProcedure, shape: .capsule, onConfirm: { fireHandoff() })
    } else {
      let isHovered = hoverCoordinator.hovered == .startProcedure
      Text("Start")
        .font(.inter(.medium, size: 14))
        .foregroundStyle(isHovered ? Color.black.opacity(0.88) : Color.white.opacity(0.96))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
          Capsule().fill(isHovered ? Color.white.opacity(0.95) : Color.clear)
        )
        .rayBanHUDPanel(shape: .capsule)
        .hoverSelectable(.startProcedure, shape: .capsule, onConfirm: { fireHandoff() })
    }
  }

  // MARK: - Helpers

  private var sourceText: String {
    switch viewModel.resolution {
    case .matchedProcedure:
      return "Found in your library."
    case .generatedSOP:
      return "Synthesized from web sources."
    case .none, .noMatch:
      return ""
    }
  }

  private var procedureTitle: String {
    switch viewModel.resolution {
    case .matchedProcedure(let candidate):
      return candidate.title
    case .generatedSOP(_, let title):
      return title
    case .none, .noMatch:
      return ""
    }
  }

  private var procedureId: String? {
    switch viewModel.resolution {
    case .matchedProcedure(let candidate): return candidate.procedureId
    case .generatedSOP(let id, _): return id
    case .none, .noMatch: return nil
    }
  }

  private func fireHandoff() {
    guard let id = procedureId else { return }
    onStart(id)
  }
}
