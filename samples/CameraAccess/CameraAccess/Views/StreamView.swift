import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel

  var body: some View {
    ZStack {
      // Dark background for letterboxing/pillarboxing
      Color.backgroundPrimary
        .edgesIgnoringSafeArea(.all)

      // Video backdrop
      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          Image(uiImage: videoFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundColor(.textPrimary)
      }

      // Recording indicator overlay
      if viewModel.recordingManager.isRecording {
        VStack {
          RecordingTimerView(duration: viewModel.recordingManager.recordingDuration)
            .padding(.top, 60)
          Spacer()
        }
      }

      // Bottom controls layer
      VStack {
        Spacer()
        ControlsView(viewModel: viewModel)
      }
      .padding(.all, 24)
    }
    .onDisappear {
      Task {
        if viewModel.recordingManager.isRecording {
          _ = await viewModel.recordingManager.stopRecording()
        }
        if viewModel.streamingStatus != .stopped {
          await viewModel.stopSession()
        }
      }
    }
    // Show captured photos from DAT SDK in a preview sheet
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: {
            viewModel.dismissPhotoPreview()
          }
        )
      }
    }
  }
}

// MARK: - Recording Timer

struct RecordingTimerView: View {
  let duration: TimeInterval

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(Color.red)
        .frame(width: 10, height: 10)
      Text(formattedDuration)
        .font(.system(size: 16, weight: .semibold, design: .monospaced))
        .foregroundColor(.textPrimary)
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.md)
    .glassPanel(cornerRadius: Radius.xl)
  }

  private var formattedDuration: String {
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%02d:%02d", minutes, seconds)
  }
}

// MARK: - Controls

struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    let isRecording = viewModel.recordingManager.isRecording

    HStack(alignment: .bottom, spacing: Spacing.md) {
      VStack(spacing: Spacing.md) {
        if !isRecording {
          CustomButton(
            title: "Start recording",
            style: .primary,
            isDisabled: false
          ) {
            viewModel.recordingManager.startRecording()
          }
        }

        CustomButton(
          title: isRecording ? "Stop recording" : "Stop streaming",
          style: .destructive,
          isDisabled: false
        ) {
          Task {
            if isRecording {
              if await viewModel.recordingManager.stopRecording() != nil {
                viewModel.showRecordingReview = true
              } else {
                viewModel.reportRecordingFailure()
              }
            }
            await viewModel.stopSession()
          }
        }
      }

      if !isRecording {
        CircleButton(icon: "camera.fill", text: nil) {
          viewModel.capturePhoto()
        }
        .accessibilityIdentifier("capture_photo_button")
      }
    }
  }
}
