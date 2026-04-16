import MWDATCore
import SwiftUI

struct RecordTabView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  let onProcedureCreated: (String) -> Void

  @State private var showStreaming = false
  @State private var showMediaPicker = false
  @State private var selectedVideoURL: URL?
  @State private var showReview = false
  @StateObject private var uploadService = UploadService()

  var body: some View {
    ZStack {
      Color.backgroundPrimary.edgesIgnoringSafeArea(.all)

      if showStreaming {
        StreamSessionView(
          wearables: wearables,
          wearablesVM: wearablesVM,
          uploadService: uploadService,
          onAcknowledgeProcedure: handleProcedureAcknowledged
        )
      } else {
        landingView
      }
    }
    .navigationTitle("Record")
    .navigationBarTitleDisplayMode(.large)
    .toolbarBackground(.hidden, for: .navigationBar)
    .sheet(isPresented: $showMediaPicker) {
      MediaPickerView(mode: .video) { url, _ in
        selectedVideoURL = url
        showMediaPicker = false
        showReview = true
      }
    }
    .sheet(isPresented: $showReview) {
      if let url = selectedVideoURL {
        ExpertRecordingReviewView(
          recordingURL: url,
          duration: 0,
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
          subtitle: wearablesVM.registrationState == .registered ? "Stream and record live" : "Connect glasses first",
          isEnabled: wearablesVM.registrationState == .registered
        ) {
          showStreaming = true
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
