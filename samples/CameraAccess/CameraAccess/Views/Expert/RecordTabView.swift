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
  @State private var showTransportPicker = false
  @State private var pendingTransport: CaptureTransport?
  @State private var showMediaPicker = false
  @State private var selectedVideoURL: URL?
  @State private var selectedVideoDuration: TimeInterval = 0
  @State private var showReview = false
  @State private var showPDFPicker = false
  @State private var pendingPDFURL: URL?
  @State private var showPDFPreview = false
  @State private var showManualUploadSheet = false
  @StateObject private var uploadService = UploadService()
  @StateObject private var manualUploadVM = ManualUploadViewModel()

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
    // Transport picker. The sheet just records the user's choice; routing
    // (registration gate, inactive prompt, full-screen recording) happens in
    // onDismiss so we don't try to present a sheet on top of the picker
    // mid-dismissal.
    .sheet(
      isPresented: $showTransportPicker,
      onDismiss: { handlePickedTransport() }
    ) {
      CaptureTransportPickerSheet(
        title: "How do you want to record?",
        subtitle: nil,
        glassesActionLabel: "Record with Glasses",
        iPhoneActionLabel: "Record with iPhone",
        onSelect: { transport in
          pendingTransport = transport
        }
      )
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
    .fileImporter(
      isPresented: $showPDFPicker,
      allowedContentTypes: [.pdf],
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result, let url = urls.first {
        pendingPDFURL = url
        showPDFPreview = true
      }
    }
    .fullScreenCover(
      isPresented: $showPDFPreview,
      onDismiss: {
        pendingPDFURL = nil
      }
    ) {
      if let url = pendingPDFURL {
        PDFPreviewView(
          pdfURL: url,
          onUpload: { pdfURL, productName in
            manualUploadVM.start(pdfURL: pdfURL, productName: productName)
            showPDFPreview = false
            // Re-present as a sheet so the user can dismiss-to-background.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
              showManualUploadSheet = true
            }
          },
          onCancel: { showPDFPreview = false }
        )
      }
    }
    .sheet(isPresented: $showManualUploadSheet) {
      ExpertManualUploadSheet(
        viewModel: manualUploadVM,
        onComplete: { procedureId in
          showManualUploadSheet = false
          onProcedureCreated(procedureId)
        },
        onDismiss: {
          showManualUploadSheet = false
          manualUploadVM.cancel()
        },
        onSendToBackground: {
          showManualUploadSheet = false
        },
        onRetry: {
          if let url = pendingPDFURL {
            manualUploadVM.start(pdfURL: url, productName: "")
          }
        }
      )
    }
  }

  private func handleProcedureAcknowledged() {
    if let id = uploadService.uploadResult?.id {
      onProcedureCreated(id)
    }
  }

  // Routes the user's transport choice after the picker sheet finishes
  // dismissing. Keeps the gate logic out of the sheet itself so the
  // registration / inactive prompts can present cleanly.
  private func handlePickedTransport() {
    guard let transport = pendingTransport else { return }
    pendingTransport = nil
    switch transport {
    case .glasses:
      if wearablesVM.registrationState != .registered {
        showRegistrationSheet = true
      } else if !wearablesVM.hasActiveDevice {
        showGlassesInactiveSheet = true
      } else {
        showStreaming = true
      }
    case .iPhone:
      showIPhoneRecording = true
    }
  }

  private var landingView: some View {
    VStack(alignment: .leading, spacing: Spacing.section) {
      Spacer(minLength: Spacing.xl)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Create a procedure")
          .font(.retraceTitle1)
          .foregroundColor(.textPrimary)
        Text("Three ways to bring in the expert's knowledge.")
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: Spacing.lg) {
        AccentedHeroCard(
          icon: "record.circle",
          title: "Record Live",
          subtitle: "Capture the task as the expert performs it."
        ) {
          showTransportPicker = true
        }

        ModeCard(
          icon: "square.and.arrow.up",
          title: "Upload video",
          subtitle: "From a video on this phone.",
          isEnabled: true
        ) {
          showMediaPicker = true
        }

        ModeCard(
          icon: "doc.fill",
          title: "Upload PDF manual",
          subtitle: "From a product manual PDF.",
          isEnabled: true
        ) {
          showPDFPicker = true
        }
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Spacing.screenPadding)
  }
}
