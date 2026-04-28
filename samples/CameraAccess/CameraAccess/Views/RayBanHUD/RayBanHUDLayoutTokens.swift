import CoreGraphics
import Foundation

/// Single source of truth for layout constants used by the Ray-Ban HUD
/// emulator and every page conformer. Lifted out of the old
/// `CoachingRayBanHUD.swift` so Coaching/Expert/Troubleshoot pages all
/// reference the same enum without one of them owning the others.
enum RayBanHUDLayoutTokens {
  static let viewportInset: CGFloat = 24
  static let contentPadding: CGFloat = 20
  static let stackSpacing: CGFloat = 12
  static let exitToPanelSpacing: CGFloat = 8
  static let cardRadius: CGFloat = 24
  static let iconFrame: CGFloat = 36
  static let completionHeight: CGFloat = 140
  static let completionActionRadius: CGFloat = 22
  static let detailHeight: CGFloat = 180
  static let stepCardMinHeight: CGFloat = 124
  /// Fixed content height for the step card's scrollable body (STEP label +
  /// title + description). Tweak to taste — at 100 the description is one
  /// short line before scrolling kicks in.
  static let stepCardContentHeight: CGFloat = 100
  static let stepSwipeMinimumDistance: CGFloat = 12
  static let stepSwipeCommitThreshold: CGFloat = 80
  static let stepSwipeCommitDuration: Double = 0.18
  static let stepLoadingTransitionDuration: Double = 0.14
  static let stepContentRevealDuration: Double = 0.18
  static let stepSwipeCommitDelayNanoseconds: UInt64 = 180_000_000
  static let exitHoldDuration: TimeInterval = 2.0
  /// Auto-confirm window for the Expert stop-recording overlay. The
  /// overlay opens on tap (or pinch-select) of the stop pill and counts
  /// down — if the user hits the X (or pinch-back / lens double-tap)
  /// before this elapses, recording continues; otherwise it stops. Per
  /// `DESIGN.md` confirmation-overlay convention.
  static let stopCountdownDuration: TimeInterval = 3.0
  /// Compact step-card description truncation cutoff before "Read more" kicks in.
  static let stepDescriptionCharacterLimit: Int = 75
  /// Single half-cycle of the green completion pulse. Full pulse = 2× this (autoreverse).
  static let completionPulseDuration: Double = 0.70
  /// Maximum width of the Exit workflow pill.
  static let exitPillMaxWidth: CGFloat = 340
  /// Page-transition slide duration. Page-nav animations derive their offset
  /// from the lens viewport size — no hard-coded "off-screen" magic numbers.
  static let pageSlideDuration: Double = 0.22
  /// Page-indicator dot diameter and spacing.
  static let pageIndicatorDotDiameter: CGFloat = 6
  static let pageIndicatorSpacing: CGFloat = 6
}
