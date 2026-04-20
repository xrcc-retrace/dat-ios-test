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
///   [3] chrome — close button (top-left), start-recording CTA before recording
struct IPhoneRecordingView: View {
  let onAcknowledgeProcedure: () -> Void
  @Environment(\.dismiss) private var dismiss
  @StateObject private var viewModel: IPhoneExpertRecordingViewModel

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
        onStop: { viewModel.stopRecording() }
      )
    } chrome: {
      chromeOverlay
    }
    .task {
      await viewModel.prepare()
    }
    .onDisappear {
      viewModel.teardown()
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

  /// Non-HUD overlays: preview loading spinner, close button, Start CTA.
  /// The HUD owns the Stop pill, so the Start button hides as soon as
  /// recording begins.
  @ViewBuilder
  private var chromeOverlay: some View {
    if !viewModel.isPreviewLive {
      ProgressView()
        .scaleEffect(1.5)
        .tint(.textPrimary)
    }

    // Close button (top-left)
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

    // Start-recording CTA — only shown before recording begins. Once
    // recording starts, the HUD's hold-to-stop pill takes over.
    if !viewModel.recordingManager.isRecording {
      VStack {
        Spacer()
        IPhoneStartRecordingButton(viewModel: viewModel)
          .padding(.all, 24)
      }
    }
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
      viewModel.startRecording()
    }
  }
}
