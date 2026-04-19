import SwiftUI

/// Coaching-flow Ray-Ban HUD surface.
///
/// Renders in the middle layer of `IPhoneCoachingLayout`: above the
/// full-bleed camera preview, below the bottom drawer. This is the
/// canvas where Retrace mirrors what would display on the Ray-Ban Meta
/// glasses HUD during a learner coaching session — Iron Man HUD track
/// demo material, step cards, visual advance-step signals, interject
/// hints, and any other learner-facing heads-up content.
///
/// **Frontend designer edits this file.** Drop HUD content into the
/// `body` below. The host layout (`IPhoneCoachingLayout`) enforces three
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
/// 3. **Hit-test pass-through by default.** The layout wraps this body
///    in `.allowsHitTesting(false)` so drawer drags and future camera
///    taps pass straight through. If a HUD element needs to accept
///    touches, wrap it in `.allowsHitTesting(true)`.
///
/// Available view-model state (all `@Published`, redraws on change):
/// - `viewModel.activity: [ActivityEntry]` — learner + AI transcripts, tool calls
/// - `viewModel.currentStepIndex: Int` — 0-indexed current step
/// - `viewModel.currentStep: ProcedureStepResponse?` — current step model
/// - `viewModel.isCompleted: Bool` — procedure finished
/// - `viewModel.showPiP: Bool` — reference clip is visible
/// - `viewModel.isMuted: Bool`, `viewModel.isAISpeaking: Bool`
/// - `viewModel.geminiConnectionState` — `.connecting / .connected / .error / .disconnected`
/// - `viewModel.voiceStatus: String` — short human-readable ("Listening", "Muted", …)
/// - `viewModel.formattedSessionDuration: String` — "m:ss"
struct CoachingRayBanHUD: View {
  @ObservedObject var viewModel: CoachingSessionViewModel

  var body: some View {
    // Designer fills this in. Camera renders through the whole surface
    // until HUD content is added.
    EmptyView()
  }
}
