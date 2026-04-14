import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
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
          .foregroundColor(.white)
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
    // Show recording review after stopping recording
    .sheet(isPresented: $viewModel.showRecordingReview) {
      if let recordingURL = viewModel.recordingManager.recordingURL {
        ExpertRecordingReviewView(
          recordingURL: recordingURL,
          duration: viewModel.recordingManager.recordingDuration,
          uploadService: viewModel.uploadService,
          onDismiss: {
            viewModel.showRecordingReview = false
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
        .foregroundColor(.white)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(Color.black.opacity(0.6))
    .cornerRadius(20)
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
    HStack(spacing: 8) {
      // Stop streaming — disabled while recording
      CustomButton(
        title: "Stop streaming",
        style: .destructive,
        isDisabled: viewModel.recordingManager.isRecording
      ) {
        Task {
          await viewModel.stopSession()
        }
      }

      // Record toggle button
      RecordButton(isRecording: viewModel.recordingManager.isRecording) {
        Task {
          if viewModel.recordingManager.isRecording {
            _ = await viewModel.recordingManager.stopRecording()
            viewModel.showRecordingReview = true
          } else {
            viewModel.recordingManager.startRecording()
          }
        }
      }

      // Photo button — hidden during recording
      if !viewModel.recordingManager.isRecording {
        CircleButton(icon: "camera.fill", text: nil) {
          viewModel.capturePhoto()
        }
        .accessibilityIdentifier("capture_photo_button")
      }
    }
  }
}

// MARK: - Record Button

struct RecordButton: View {
  let isRecording: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .stroke(Color.white, lineWidth: 3)
          .frame(width: 56, height: 56)

        if isRecording {
          RoundedRectangle(cornerRadius: 4)
            .fill(Color.red)
            .frame(width: 20, height: 20)
        } else {
          Circle()
            .fill(Color.red)
            .frame(width: 44, height: 44)
        }
      }
    }
  }
}
