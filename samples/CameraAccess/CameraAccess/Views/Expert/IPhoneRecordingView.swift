import AVFoundation
import SwiftUI

/// iPhone-native expert-recording screen. Mirrors `StreamSessionView` +
/// `StreamView` but uses an `AVCaptureSession` preview layer instead of the
/// DAT SDK frame publisher.
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
    RetraceScreen {

      // Live camera preview (handled by AVCaptureVideoPreviewLayer — hardware
      // accelerated, no per-frame UIImage work needed).
      IPhoneCameraPreview(previewLayer: viewModel.previewLayer)
        .edgesIgnoringSafeArea(.all)

      if !viewModel.isPreviewLive {
        ProgressView()
          .scaleEffect(1.5)
          .tint(.textPrimary)
      }

      // Recording indicator at top
      if viewModel.recordingManager.isRecording {
        VStack {
          IPhoneRecordingTimer(duration: viewModel.recordingManager.recordingDuration)
            .padding(.top, 60)
          Spacer()
        }
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

      // Bottom controls
      VStack {
        Spacer()
        IPhoneRecordingControls(viewModel: viewModel)
          .padding(.all, 24)
      }
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
}

// MARK: - Controls

private struct IPhoneRecordingControls: View {
  @ObservedObject var viewModel: IPhoneExpertRecordingViewModel

  var body: some View {
    let isRecording = viewModel.recordingManager.isRecording
    VStack(spacing: Spacing.md) {
      if !isRecording {
        CustomButton(
          title: "Start recording",
          style: .primary,
          isDisabled: !viewModel.isPreviewLive
        ) {
          viewModel.startRecording()
        }
      } else {
        CustomButton(
          title: "Stop recording",
          style: .destructive,
          isDisabled: false
        ) {
          viewModel.stopRecording()
        }
      }
    }
  }
}

// MARK: - Timer

private struct IPhoneRecordingTimer: View {
  let duration: TimeInterval

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(Color.red)
        .frame(width: 10, height: 10)
      Text(formatted)
        .font(.system(size: 16, weight: .semibold, design: .monospaced))
        .foregroundColor(.textPrimary)
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.md)
    .glassPanel(cornerRadius: Radius.xl)
  }

  private var formatted: String {
    let mins = Int(duration) / 60
    let secs = Int(duration) % 60
    return String(format: "%02d:%02d", mins, secs)
  }
}
