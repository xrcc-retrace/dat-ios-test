import Foundation

/// Audio + haptic feedback hooks for coaching-session completion events.
///
/// Currently a no-op — the visual celebration ships first; the sound
/// asset choice is deferred. When an asset lands, populate
/// `playStepComplete()` here in one place and every advance call site
/// will pick it up. Centralizing the hook also keeps the call sites
/// (`CoachingSessionViewModel.startForwardCelebration`) free of audio
/// concerns.
enum CompletionFeedback {
  /// Fired the moment a forward `advance_step` lands and the celebration
  /// timeline begins (t=0 of the overlay sequence). Intended duration of
  /// the eventual sound effect is well under 0.7s so it lands before the
  /// slide-out kicks in.
  static func playStepComplete() {
    // Intentionally empty for now. See file header.
  }
}
