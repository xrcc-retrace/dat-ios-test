import AVFoundation
import SwiftUI

/// iPhone-native expert-recording screen. Mirrors `StreamSessionView` +
/// `StreamView` but uses an `AVCaptureSession` preview layer instead of the
/// DAT SDK frame publisher.
///
/// Layering (via `ExpertRecordingLayout`):
///   [0] black fallback
///   [1] `IPhoneCameraPreview`
///   [2] `ExpertRayBanHUD` — tip card, recording chip, stop pill, transcript
///   [3] chrome — close button (top-left), pre-recording toggles + Start CTA
struct IPhoneRecordingView: View {
  let onAcknowledgeProcedure: () -> Void
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var appOrientationController: AppOrientationController
  @StateObject private var viewModel: IPhoneExpertRecordingViewModel

  // Gesture-debug overlay hidden by default so demo footage stays clean.
  // Flipped from the pre-recording chrome toggle. Resets per presentation.
  @State private var showGestureDebug: Bool = false
  // Output orientation for the next recording. Off = portrait 720×1280 (the
  // historical default); on = landscape 1280×720 locked to landscapeRight.
  // Flipping this immediately rotates the capture output + preview; the
  // writer picks up the matching dimensions on the next Start recording.
  @State private var landscapeOutput: Bool = false
  // Tracks the scene's current interface orientation so the observer can
  // forward rotation into the camera preview. Only meaningful when
  // `landscapeOutput` is off — when landscape is on, preview is pinned.
  @State private var currentInterfaceOrientation: UIInterfaceOrientation = .portrait

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
      ExpertRayBanHUD(
        recordingManager: viewModel.recordingManager,
        hud: viewModel.hudViewModel,
        showGestureDebug: showGestureDebug,
        onStop: { viewModel.stopRecording() }
      )
    } chrome: {
      chromeOverlay
    }
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
      // the layout matches the current phone orientation — skipped when
      // landscape output is already on (that path pins preview to 0°).
      if !landscapeOutput {
        viewModel.camera.setPreviewInterfaceOrientation(resolved)
      }
    }
    .onDisappear {
      viewModel.teardown()
      UIDevice.current.endGeneratingDeviceOrientationNotifications()
      appOrientationController.unlock()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      let resolved = resolveInterfaceOrientation()
      currentInterfaceOrientation = resolved
      // When landscape output is locked, preview stays pinned to
      // landscapeRight regardless of device orientation — per intent.
      guard !landscapeOutput else { return }
      viewModel.camera.setPreviewInterfaceOrientation(resolved)
    }
    .onChange(of: landscapeOutput) { _, newValue in
      viewModel.camera.setCaptureLandscapeOutput(newValue)
      // Flipping back to portrait: restore preview to whatever the phone
      // is currently showing so the user isn't stuck looking at a rotated
      // frame after toggling off.
      if !newValue {
        viewModel.camera.setPreviewInterfaceOrientation(currentInterfaceOrientation)
      }
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

  /// Non-HUD overlays: preview loading spinner, close button, pre-recording
  /// toggle cluster, Start CTA. The HUD owns the Stop pill, so everything in
  /// the pre-recording bundle hides as soon as recording begins.
  @ViewBuilder
  private var chromeOverlay: some View {
    if !viewModel.isPreviewLive {
      ProgressView()
        .scaleEffect(1.5)
        .tint(.textPrimary)
    }

    // Pre-recording chrome: close button + toggle bundle + Start CTA. Hides
    // the moment recording begins — the HUD takes over the stop affordance.
    if !viewModel.recordingManager.isRecording {
      ZStack {
        VStack {
          HStack {
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
            .padding(.top, 20)
            Spacer()
          }
          Spacer()
        }

        VStack(spacing: 12) {
          Spacer()
          IPhonePreRecordingToggleCluster(
            showGestureDebug: $showGestureDebug,
            landscapeOutput: $landscapeOutput,
            isDisabled: viewModel.recordingManager.isStarting
          )
          IPhoneStartRecordingButton(
            viewModel: viewModel,
            landscapeOutput: landscapeOutput
          )
        }
        .padding(.all, 24)
      }
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

// MARK: - Pre-recording toggle cluster

/// Compact glass-panel cluster with the two pre-recording switches:
/// Gesture debug (overlay visibility) and Landscape output (MP4 orientation).
/// Both disabled during the startup window so the user can't flip a toggle
/// mid-configuration.
private struct IPhonePreRecordingToggleCluster: View {
  @Binding var showGestureDebug: Bool
  @Binding var landscapeOutput: Bool
  let isDisabled: Bool

  var body: some View {
    VStack(spacing: 8) {
      Toggle(isOn: $showGestureDebug) {
        Label("Gesture debug", systemImage: "ladybug")
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(.textPrimary)
      }
      .tint(.appPrimary)

      Toggle(isOn: $landscapeOutput) {
        Label("Landscape output", systemImage: "rectangle.landscape")
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(.textPrimary)
      }
      .tint(.appPrimary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .glassPanel(cornerRadius: Radius.lg)
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.6 : 1.0)
  }
}

// MARK: - Start button (pre-recording only)

private struct IPhoneStartRecordingButton: View {
  @ObservedObject var viewModel: IPhoneExpertRecordingViewModel
  let landscapeOutput: Bool

  var body: some View {
    let isStarting = viewModel.recordingManager.isStarting
    CustomButton(
      title: isStarting ? "Starting…" : "Start recording",
      style: .primary,
      isDisabled: !viewModel.isPreviewLive || isStarting
    ) {
      viewModel.startRecording(landscape: landscapeOutput)
    }
  }
}
