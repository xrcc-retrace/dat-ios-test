import SwiftUI

/// The state surface every HUD-owning VM exposes to the shared
/// gesture-debug stack. Both `GeminiLiveSessionBase` (Coaching +
/// Troubleshoot) and `ExpertRecordingHUDViewModel` already implement
/// every one of these properties — conformance is just a marker
/// extension.
///
/// New fields added here become a single build error the compiler points
/// to in each VM, instead of the three HUD files getting out of sync.
@MainActor
protocol HandGestureDebugProvider: ObservableObject {
  var latestHandFrame: HandLandmarkFrame? { get }
  var recentPinchDragEvents: [PinchDragLogEntry] { get }

  // Pinch threshold (pulled from `PinchDragRecognizer.Config()`).
  // 2D only — pinch z-gating was removed; MediaPipe's fingertip depth
  // is too noisy to use as a contact gate.
  var indexPinchContactThreshold: Float { get }

  // Orientation gate — drives the POSE OK / POSE OFF chip.
  var gatePalmFacingZMin: Float { get }
  var gatePalmFacingZMax: Float { get }
  var gateHandSizeMin: Float { get }

  /// True while the recognizer is holding a deferred `.select` waiting
  /// for a possible second tap. Drives the overlay's "TAP 1/2" chip.
  var pendingSelectActive: Bool { get }

  /// Quadrant the thumb currently occupies, or nil while idle / in the
  /// center dead zone. Drives the cross-UI's lit box.
  var currentHighlightQuadrant: PinchDragQuadrant? { get }

  // Persistent pinch-trajectory markers.
  var lastContactStartPosition: CGPoint? { get }
  var lastContactReleasePosition: CGPoint? { get }
}

/// The single canonical mount point for the Ray-Ban HUD gesture-debug
/// surface. Drops into any HUD by passing the owning VM as `provider`.
///
/// Composes:
///   - `HandLandmarkDebugOverlay` (full-bleed) — live landmark dots,
///     distance lines, contact indicator, persistent START/END markers,
///     status badge (pinch state + pose gate)
///   - `MicroGestureDebugLog` (top-center at ~1/4 screen height) —
///     scrollable feed of recent `PinchDragEvent`s
///
/// Changing layout or adding new gesture-debug surfaces? Edit this file,
/// not three HUD files.
struct HandGestureDebugStack<Provider: HandGestureDebugProvider>: View {
  @ObservedObject var provider: Provider

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        // Full-bleed landmark overlay underneath the log so the numbers
        // don't obscure the dots.
        HandLandmarkDebugOverlay(
          frame: provider.latestHandFrame,
          indexContactThreshold: provider.indexPinchContactThreshold,
          gatePalmFacingZMin: provider.gatePalmFacingZMin,
          gatePalmFacingZMax: provider.gatePalmFacingZMax,
          gateHandSizeMin: provider.gateHandSizeMin,
          pendingSelectActive: provider.pendingSelectActive,
          contactStartNormalized: provider.lastContactStartPosition,
          contactEndNormalized: provider.lastContactReleasePosition
        )

        // Cross-UI + event feed, stacked top-center. Cross sits just
        // above the log so the highlighting signal and the committed-
        // event history read as one unit. Anchoring at 18% of screen
        // height keeps both clear of the notch.
        VStack(spacing: 10) {
          PinchDragCrossUI(
            currentHighlightQuadrant: provider.currentHighlightQuadrant
          )
          MicroGestureDebugLog(entries: provider.recentPinchDragEvents)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, geometry.size.height * 0.18)
      }
    }
    .allowsHitTesting(false)
  }
}
