import AVFoundation
import MWDATCore
import SwiftUI

struct RecordTabView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  let onProcedureCreated: (String) -> Void
  let onExit: () -> Void

  @State private var showStreaming = false
  @State private var showIPhoneRecording = false
  @State private var showRegistrationSheet = false
  @State private var showMediaPicker = false
  @State private var selectedVideoURL: URL?
  @State private var selectedVideoDuration: TimeInterval = 0
  @State private var showReview = false
  @StateObject private var uploadService = UploadService()

  var body: some View {
    RetraceScreen {
      landingView
    }
    .navigationTitle("Record")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          onExit()
        } label: {
          Image(systemName: "chevron.backward")
            .foregroundColor(.textSecondary)
        }
      }
    }
    .retraceNavBar()
    .fullScreenCover(isPresented: $showStreaming) {
      StreamSessionView(
        wearables: wearables,
        wearablesVM: wearablesVM,
        uploadService: uploadService,
        onAcknowledgeProcedure: handleProcedureAcknowledged
      )
    }
    .fullScreenCover(isPresented: $showIPhoneRecording) {
      IPhoneRecordingView(
        uploadService: uploadService,
        onAcknowledgeProcedure: handleProcedureAcknowledged
      )
    }
    .sheet(isPresented: $showRegistrationSheet) {
      RegistrationPromptSheet(viewModel: wearablesVM) {
        // Auto-proceed to streaming once the user finishes registration.
        showStreaming = true
      }
    }
    .sheet(isPresented: $showMediaPicker) {
      MediaPickerView(mode: .video) { url, _ in
        Task {
          let seconds = (try? await AVURLAsset(url: url).load(.duration))?.seconds ?? 0
          await MainActor.run {
            selectedVideoURL = url
            selectedVideoDuration = seconds
            showMediaPicker = false
            showReview = true
          }
        }
      }
    }
    .fullScreenCover(isPresented: $showReview) {
      if let url = selectedVideoURL {
        ExpertRecordingReviewView(
          recordingURL: url,
          duration: selectedVideoDuration,
          uploadService: uploadService,
          onDismiss: {
            selectedVideoURL = nil
            showReview = false
          },
          onAcknowledgeResult: handleProcedureAcknowledged
        )
      }
    }
  }

  private func handleProcedureAcknowledged() {
    if let id = uploadService.uploadResult?.id {
      onProcedureCreated(id)
    }
  }

  private var landingView: some View {
    VStack(spacing: Spacing.section) {
      Spacer()

      Image(systemName: "video.fill")
        .font(.system(size: 48))
        .foregroundColor(.textTertiary)

      VStack(spacing: Spacing.md) {
        Text("Record a New Procedure")
          .font(.retraceTitle2)
          .fontWeight(.semibold)
          .foregroundColor(.textPrimary)

        Text("Stream from your glasses and record,\nor upload an existing video")
          .font(.retraceBody)
          .foregroundColor(.textSecondary)
          .multilineTextAlignment(.center)
      }

      Spacer()

      VStack(spacing: Spacing.lg) {
        ModeCard(
          icon: "eyeglasses",
          title: "Record with Glasses",
          subtitle: "Stream and record live",
          isEnabled: true
        ) {
          // Gate on registration at the tap — not at render — so unpaired
          // users still see the option. Show the registration sheet when
          // not yet connected; it auto-proceeds to streaming on success.
          if wearablesVM.registrationState == .registered {
            showStreaming = true
          } else {
            showRegistrationSheet = true
          }
        }

        ModeCard(
          icon: "iphone",
          title: "Record with iPhone",
          subtitle: "Use the phone's back camera + mic",
          isEnabled: true
        ) {
          showIPhoneRecording = true
        }

        ModeCard(
          icon: "square.and.arrow.up",
          title: "Upload Video",
          subtitle: "Select a video from your library",
          isEnabled: true
        ) {
          showMediaPicker = true
        }
      }

      Spacer()
    }
    .padding(.horizontal, Spacing.screenPadding)
  }
}
