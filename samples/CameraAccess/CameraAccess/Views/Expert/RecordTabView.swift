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
  @State private var showGlassesInactiveSheet = false
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
            .foregroundColor(.textPrimary)
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
    .sheet(isPresented: $showGlassesInactiveSheet) {
      GlassesInactiveSheet(iPhoneAlternativeTitle: "Record with iPhone instead") {
        showIPhoneRecording = true
      }
    }
    .sheet(isPresented: $showMediaPicker) {
      MediaPickerView(mode: .video) { url, _ in
        Task {
          let seconds = (try? await AVURLAsset(url: url).load(.duration))?.seconds ?? 0
          await MainActor.run {
            selectedVideoURL = url
            selectedVideoDuration = seconds
            // Sheet dismissal is driven by picker.dismiss(animated:true)
            // inside the coordinator — no need to flip the binding here.
          }
        }
      }
    }
    // Symmetric gates: the review opens exactly once, whichever event arrives
    // last. Needed because the picker calls picker.dismiss(animated:true)
    // synchronously from the coordinator while the duration-loading Task runs
    // on its own clock — either can finish first, and relying on onDismiss
    // alone loses the late arrival and leaves the user on a blank screen.
    .onChange(of: showMediaPicker) { _, isShowing in
      if !isShowing, selectedVideoURL != nil, !showReview {
        showReview = true
      }
    }
    .onChange(of: selectedVideoURL) { _, newURL in
      if newURL != nil, !showMediaPicker, !showReview {
        showReview = true
      }
    }
    .fullScreenCover(
      isPresented: $showReview,
      onDismiss: {
        selectedVideoURL = nil
        selectedVideoDuration = 0
      }
    ) {
      if let url = selectedVideoURL {
        ExpertRecordingReviewView(
          recordingURL: url,
          duration: selectedVideoDuration,
          uploadService: uploadService,
          onDismiss: { showReview = false },
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
          .font(.retraceFace(.semibold, size: 22))
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
          // Three-way gate at the tap:
          //   - Not registered  → Meta AI pairing sheet
          //   - Registered but glasses not awake / in range → inactive prompt
          //   - Registered + active → straight into streaming
          if wearablesVM.registrationState != .registered {
            showRegistrationSheet = true
          } else if !wearablesVM.hasActiveDevice {
            showGlassesInactiveSheet = true
          } else {
            showStreaming = true
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
