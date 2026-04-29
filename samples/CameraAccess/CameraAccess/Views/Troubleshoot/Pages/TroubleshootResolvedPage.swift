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

  var body: some View {
    VStack(spacing: 8) {
      Spacer(minLength: 0)

      DiagnosticPhaseLensBar(phase: viewModel.phase)
      TroubleshootStageHeaderCard(
        stage: .findFix,
        title: procedureTitle,
        bodyText: sourceText
      )
      startPill
      rediagnosePill
      bottomActionRow

      Spacer(minLength: 0)
    }
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, RayBanHUDLayoutTokens.contentPadding)
    // Focus-engine handler. `defaultFocus = .startProcedure` lands the
    // cursor on the Start pill on appear; rediagnose is the secondary
    // escape path one swipe-down away. The voice label is "rediagnose"
    // (not "try again") to avoid colliding with the existing "Try again"
    // semantics in the handoffError state of the start pill.
    .hudInputHandler { coord in
      TroubleshootPageHandler(
        coordinator: coord,
        focusedControl: .startProcedure,
        voiceCommandLabel: "start",
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
      // Forward-path action — leading icon + text signals "primary"
      // (no permanent yellow outline; that was the hover-ring color
      // and made the focus signal ambiguous). The unified yellow
      // hover ring lands here on appear via default focus and is the
      // only yellow visual on the page. See DESIGN.md → Pills.
      HStack(spacing: 8) {
        Image(systemName: "arrow.right")
          .font(.system(size: 13, weight: .semibold))
        Text("Start")
          .font(.inter(.medium, size: 14))
      }
      .foregroundStyle(Color.white.opacity(0.96))
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
      .rayBanHUDPanel(shape: .capsule)
      .hoverSelectable(.startProcedure, shape: .capsule, onConfirm: { fireHandoff() })
    }
  }

  private var rediagnosePill: some View {
    // Secondary path — text-only at rest plus the canonical
    // `arrow.clockwise` redo glyph so the affordance reads at a
    // glance. No yellow accent at rest; only the unified hover ring
    // on focus. Stays mounted in all three startPill states so the
    // user always has an escape route — particularly important when
    // handoffError leaves the primary pill stuck on "Try again".
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
