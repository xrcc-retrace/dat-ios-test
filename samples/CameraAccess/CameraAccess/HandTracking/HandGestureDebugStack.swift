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

  // Pinch thresholds (identical in all three VMs — pulled from
  // `PinchDragRecognizer.Config()`). 2D only — pinch z-gating was
  // removed; MediaPipe's fingertip depth is too noisy to use as a
  // contact gate.
  var indexPinchContactThreshold: Float { get }
  var middlePinchContactThreshold: Float { get }

  // Orientation gate — drives the POSE OK / POSE OFF chip.
  var gatePalmFacingZMin: Float { get }
  var gatePalmFacingZMax: Float { get }
  var gateHandSizeMin: Float { get }

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
          middleContactThreshold: provider.middlePinchContactThreshold,
          gatePalmFacingZMin: provider.gatePalmFacingZMin,
          gatePalmFacingZMax: provider.gatePalmFacingZMax,
          gateHandSizeMin: provider.gateHandSizeMin,
          contactStartNormalized: provider.lastContactStartPosition,
          contactEndNormalized: provider.lastContactReleasePosition
        )

        // Event feed anchored top-center at 25% screen height — clear of
        // the notch, clear of the primary HUD controls at the bottom.
        MicroGestureDebugLog(entries: provider.recentPinchDragEvents)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .padding(.top, geometry.size.height * 0.25)
      }
    }
    .allowsHitTesting(false)
  }
}
