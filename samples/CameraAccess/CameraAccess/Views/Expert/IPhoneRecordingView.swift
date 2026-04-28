import AVFoundation
import SwiftUI

/// iPhone-native expert-recording screen. Mirrors `StreamSessionView` +
/// `StreamView` but uses an `AVCaptureSession` preview layer instead of the
/// DAT SDK frame publisher.
///
/// Layering (via `ExpertRecordingLayout`):
///   [0] black fallback
///   [1] `IPhoneCameraPreview`
///   [2] Ray-Ban HUD emulator hosting `ExpertNarrationTipPage`
///   [3] chrome — close button (top-left), mic-source badge (top-right),
///       transcript (above the lens), Start CTA (bottom)
///
/// Pre-recording dev toggles (gesture debug, landscape output) used to live
/// in this screen. Both moved out — debug overlays are now driven by the
/// global `@AppStorage("debugMode")` flag set in Server Settings, and
/// landscape recording is deprecated (rotating the phone produces the same
/// result via the natural orientation observer).
struct IPhoneRecordingView: View {
  let onAcknowledgeProcedure: () -> Void
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var appOrientationController: AppOrientationController
  @StateObject private var viewModel: IPhoneExpertRecordingViewModel

  @AppStorage("debugMode") private var debugMode: Bool = false
  @AppStorage("hudAdditiveBlend") private var hudAdditiveBlend: Bool = false
  // Tracks the scene's current interface orientation so the observer can
  // forward rotation into the camera preview.
  @State private var currentInterfaceOrientation: UIInterfaceOrientation = .portrait
  // Active lens page. Expert ships with one page (`ExpertNarrationTipPage`),
  // so the emulator's gestures don't actually navigate today — but the
  // wiring stays consistent with Coaching/Troubleshoot.
  @State private var expertPageIndex: Int = 0

  init(
    uploadService: UploadService,
    onAcknowledgeProcedure: @escaping () -> Void
  ) {
    self._viewModel = StateObject(
      wrappedValue: IPhoneExpertRecordingViewModel(uploadService: uploadService)
    )
    self.onAcknowledgeProcedure = onAcknowledgeProcedure
  }

  var body: some View {
    ExpertRecordingLayout {
      // Live camera preview (handled by AVCaptureVideoPreviewLayer — hardware
      // accelerated, no per-frame UIImage work needed).
      IPhoneCameraPreview(previewLayer: viewModel.previewLayer)
    } hud: {
      // Lens is hidden until the user hits Start. Pre-recording the
      // expert sees just the camera preview + chrome's Start CTA — no
      // narration card, no stop pill, nothing in the lens to look at
      // or hover. The lens fades in on `isRecording` flipping true so
      // the moment recording begins the expert has the narration card,
      // status row, and stop pill in place.
      if viewModel.recordingManager.isRecording {
        RayBanHUDEmulator(
          pageCount: 1,
          pageIndex: $expertPageIndex,
          showBoundary: debugMode,
          additiveBlend: hudAdditiveBlend,
          additiveSurfaceVariant: .lowTint,
          // Lens double-tap → focus-engine `.dismiss`. The page handler
          // ignores this (returns false), so it's a no-op until the
          // stop confirmation overlay pushes its handler — at which
          // point lens double-tap cancels the pending stop. Mirrors
          // Coaching's pinch-back / lens-double-tap parity.
          enableDismissGesture: true
        ) { _ in
          ExpertNarrationTipPage(
            recordingManager: viewModel.recordingManager,
            hud: viewModel.hudViewModel,
            onStop: { viewModel.stopRecording() }
          )
        }
        .transition(.opacity)
      }
    } chrome: {
      chromeOverlay
    }
    .animation(.easeInOut(duration: 0.18), value: viewModel.recordingManager.isRecording)
    .task {
      await viewModel.prepare()
    }
    .onAppear {
      // Broaden the allowed orientation mask so SwiftUI chrome can follow
      // the phone into landscape, same as the learner coaching flow.
      appOrientationController.setAllowed([.portrait, .landscapeLeft, .landscapeRight])
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
      let resolved = resolveInterfaceOrientation()
      currentInterfaceOrientation = resolved
      // Seed the preview from the scene's actual interface orientation so
      // the layout matches the current phone orientation.
      viewModel.camera.setPreviewInterfaceOrientation(resolved)
    }
    .onDisappear {
      viewModel.teardown()
      UIDevice.current.endGeneratingDeviceOrientationNotifications()
      appOrientationController.unlock()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      let resolved = resolveInterfaceOrientation()
      currentInterfaceOrientation = resolved
      viewModel.camera.setPreviewInterfaceOrientation(resolved)
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
    .sheet(isPresented: $viewModel.showRecordingReview) {
      if let recordingURL = viewModel.recordingManager.recordingURL {
        ExpertRecordingReviewView(
          recordingURL: recordingURL,
          duration: viewModel.recordingManager.recordingDuration,
          uploadService: viewModel.uploadService,
          onDismiss: {
            viewModel.showRecordingReview = false
            dismiss()
          },
          onAcknowledgeResult: {
            onAcknowledgeProcedure()
            dismiss()
          }
        )
      }
    }
  }

  /// Non-HUD overlays. Two phases:
  ///   • Pre-recording — close button (top-left), mic-source badge (top-right),
  ///     Start CTA (bottom).
  ///   • Recording — mic-source badge (top-right), rolling transcript card
  ///     (above the lens). The recording status chip + audio meter stays
  ///     *inside* the lens alongside the stop pill — paired unit, both belong
  ///     under the Ray-Ban 600×600 boundary. See `ExpertNarrationTipPage`.
  @ViewBuilder
  private var chromeOverlay: some View {
    if !viewModel.isPreviewLive {
      ProgressView()
        .scaleEffect(1.5)
        .tint(.textPrimary)
    }

    // Top row: pre-recording shows close (top-left) + mic-source badge
    // (top-right). When recording starts, the mic badge moves *into*
    // the lens (sits in the in-lens status row alongside the timer),
    // so chrome stops rendering it to avoid double-up.
    VStack {
      HStack(alignment: .top) {
        if !viewModel.recordingManager.isRecording {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 17, weight: .semibold))
              .foregroundColor(.textPrimary)
              .frame(width: 36, height: 36)
              .glassPanel(cornerRadius: Radius.full)
          }
          .padding(.leading, 20)

          Spacer()

          ExpertHUDMicSourceBadge(micSource: viewModel.hudViewModel.micSource)
            .padding(.trailing, 20)
        } else {
          Spacer()
        }
      }
      .padding(.top, 20)

      Spacer()

      // Transcript card is debug-only — it collides with the tip
      // carousel and the in-lens status row at recording-flow scale.
      // Surfaced via Server Settings → Debug for engineers verifying
      // the recognizer; hidden in normal recording sessions.
      if debugMode,
         viewModel.recordingManager.isRecording,
         viewModel.hudViewModel.transcriptAvailable {
        ExpertHUDRollingTranscriptCard(segments: viewModel.hudViewModel.transcript)
          .padding(.horizontal, 20)
      }
    }

    // Pre-recording bottom: Start CTA only. Toggle cluster removed —
    // gesture debug is a global setting now, and landscape output is
    // deprecated (just rotate the phone).
    if !viewModel.recordingManager.isRecording {
      VStack(spacing: 12) {
        Spacer()
        IPhoneStartRecordingButton(viewModel: viewModel)
      }
      .padding(.all, 24)
    }

    // Hand-tracking dev overlay — landmark dots, pinch-drag cross, event
    // log. Sits above the rest of chrome but allows hit-testing through.
    // Reads from the single shared `HandGestureService` regardless of mode.
    if debugMode {
      HandGestureDebugStack(provider: HandGestureService.shared)
    }
  }

  private func resolveInterfaceOrientation() -> UIInterfaceOrientation {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first(where: { $0.activationState == .foregroundActive })
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    return scene?.interfaceOrientation ?? .portrait
  }
}

// MARK: - Start button (pre-recording only)

private struct IPhoneStartRecordingButton: View {
  @ObservedObject var viewModel: IPhoneExpertRecordingViewModel

  var body: some View {
    let isStarting = viewModel.recordingManager.isStarting
    CustomButton(
      title: isStarting ? "Starting…" : "Start recording",
      style: .primary,
      isDisabled: !viewModel.isPreviewLive || isStarting
    ) {
      // Always portrait/natural orientation. The pinned-landscape mode
      // was deprecated — rotating the phone gives the same result via
      // the orientation observer above.
      viewModel.startRecording(landscape: false)
    }
  }
}
