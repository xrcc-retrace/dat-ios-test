import SwiftUI

/// Troubleshoot-flow Ray-Ban HUD surface.
///
/// Renders in the middle layer of `IPhoneCoachingLayout`: above the
/// full-bleed camera preview, below the bottom drawer. This is the
/// canvas where Retrace mirrors what would display on the Ray-Ban Meta
/// glasses HUD during a diagnostic troubleshoot session — identified
/// product chips, phase indicators, resolution callouts, visual
/// handoff cues, and any other heads-up content surfaced while the
/// user is describing a broken device.
///
/// **Frontend designer edits this file.** Drop HUD content into the
/// `body` below. The host layout (`IPhoneCoachingLayout`) enforces two
/// invariants so you can't accidentally break the camera-first UX:
///
/// 1. **Full-screen bounds.** The layout sizes this view to match the
///    camera preview exactly (ignores safe areas). Lay out content
///    relative to the full screen; add per-element safe-area insets if
///    a specific HUD element should avoid the status bar / home indicator.
/// 2. **Fully transparent.** Never apply a background fill, blur, or
///    translucent tint to a container that spans this view. The camera
///    must be visible through every pixel where you aren't actively
///    drawing HUD content. Individual shapes / pills / text may of
///    course be opaque.
///
/// HUD content is hit-testable. Keep interactive controls small and
/// specifically placed; fill the rest of the surface with `Color.clear`
/// so taps in empty zones still fall through to the drawer handle
/// beneath.
///
/// Available view-model state (all `@Published`, redraws on change):
/// - `viewModel.activity: [ActivityEntry]` — user + AI transcripts, tool calls
/// - `viewModel.phase: DiagnosticPhase` — `.discovering / .diagnosing / .resolving / .resolved`
/// - `viewModel.identifiedProduct: IdentifiedProduct?` — product name + category + confidence
/// - `viewModel.candidateProcedures: [CandidateProcedure]` — matched SOPs
/// - `viewModel.resolution: DiagnosticResolution?` — final matched / generated procedure
/// - `viewModel.handoffInFlight: Bool`, `viewModel.handoffError: String?`
/// - `viewModel.isMuted: Bool`, `viewModel.isAISpeaking: Bool`
/// - `viewModel.geminiConnectionState` — `.connecting / .connected / .error / .disconnected`
/// - `viewModel.voiceStatus: String` — short human-readable ("Listening", "Muted", …)
/// - `viewModel.latestHandFrame`, `viewModel.recentPinchDragEvents` — hand
///   tracking state; drives the landmark overlay + pinch event log below.
struct TroubleshootRayBanHUD: View {
  @ObservedObject var viewModel: DiagnosticSessionViewModel

  var body: some View {
    ZStack {
      // Single shared gesture-debug stack — composes the landmark overlay
      // + event log with identical placement across Coaching, Expert, and
      // Troubleshoot HUDs. See HandGestureDebugStack.swift.
      HandGestureDebugStack(provider: viewModel)
    }
  }
}
