import SwiftUI

struct ExpertRecordingReviewView: View {
  let recordingURL: URL
  let duration: TimeInterval
  @ObservedObject var uploadService: UploadService
  let onDismiss: () -> Void
  var onAcknowledgeResult: (() -> Void)? = nil

  @State private var fileSize: String = ""

  var body: some View {
    NavigationStack {
      RetraceScreen {

        ScrollView {
          VStack(spacing: Spacing.screenPadding) {
            RecordingPreviewPlayer(url: recordingURL)

            Text("\(formattedDuration) · \(fileSize)")
              .font(.retraceCaption1)
              .foregroundColor(.textSecondary)
              .monospacedDigit()

            // Upload state
            if uploadService.isUploading {
              VStack(spacing: Spacing.lg) {
                Text("Uploading...")
                  .foregroundColor(.textSecondary)

                ProgressView(value: uploadService.uploadProgress)
                  .tint(.textPrimary)

                Text("\(Int(uploadService.uploadProgress * 100))%")
                  .font(.system(size: 14, design: .monospaced))
                  .foregroundColor(.textSecondary)
              }
              .padding(.horizontal)
            }

            // Processing state
            if uploadService.isProcessing {
              VStack(spacing: Spacing.xl) {
                ProgressView()
                  .scaleEffect(1.5)
                  .tint(.textPrimary)

                Text("Processing with AI...")
                  .font(.retraceHeadline)
                  .foregroundColor(.textPrimary)

                Text("This may take a minute")
                  .font(.retraceSubheadline)
                  .foregroundColor(.textSecondary)
              }
              .padding(Spacing.screenPadding)
              .frame(maxWidth: .infinity)
              .background(Color.surfaceBase)
              .cornerRadius(Radius.lg)
            }

            // Error
            if let error = uploadService.uploadError {
              Text(error)
                .font(.retraceCallout)
                .foregroundColor(.semanticError)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            }

            Spacer(minLength: 20)

            // Action buttons
            if uploadService.uploadResult == nil && !uploadService.isProcessing {
              VStack(spacing: Spacing.lg) {
                CustomButton(
                  title: "Upload to Server",
                  style: .primary,
                  isDisabled: uploadService.isUploading
                ) {
                  Task {
                    await uploadService.uploadRecording(fileURL: recordingURL)
                  }
                }

                CustomButton(
                  title: "Discard",
                  style: .destructive,
                  isDisabled: uploadService.isUploading
                ) {
                  try? FileManager.default.removeItem(at: recordingURL)
                  onDismiss()
                }
              }
            } else if let result = uploadService.uploadResult {
              NavigationLink {
                ProcedureReviewView(
                  initialProcedure: result,
                  serverBaseURL: uploadService.serverBaseURL,
                  onConfirmed: {
                    onAcknowledgeResult?()
                    onDismiss()
                  }
                )
              } label: {
                ReviewWorkflowButtonLabel()
              }
              .buttonStyle(ScaleButtonStyle())
            }
          }
          .padding(Spacing.screenPadding)
        }
      }
      .navigationTitle("Review")
      .navigationBarTitleDisplayMode(.inline)
      .retraceNavBar()
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Close") { onDismiss() }
            .foregroundColor(.textPrimary)
        }
      }
      .onAppear {
        loadFileSize()
      }
    }
  }

  private var formattedDuration: String {
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }

  private func loadFileSize() {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: recordingURL.path),
          let size = attrs[.size] as? Int64
    else {
      fileSize = "\u{2014}"
      return
    }
    if size > 1024 * 1024 {
      fileSize = String(format: "%.1f MB", Double(size) / (1024 * 1024))
    } else {
      fileSize = String(format: "%d KB", size / 1024)
    }
  }
}

// MARK: - Supporting Views

struct InfoItem: View {
  let label: String
  let value: String

  var body: some View {
    VStack(spacing: Spacing.xs) {
      Text(label)
        .font(.retraceCaption1)
        .foregroundColor(.textSecondary)
      Text(value)
        .font(.retraceTitle3)
        .foregroundColor(.textPrimary)
    }
  }
}

// MARK: - Review Workflow Button Label

struct ReviewWorkflowButtonLabel: View {
  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "checkmark.circle.fill")
        .font(.retraceHeadline)
      Text("Review workflow")
        .font(.retraceFace(.semibold, size: 17))
      Spacer(minLength: Spacing.xs)
      Image(systemName: "chevron.right")
        .font(.retraceSubheadline)
        .fontWeight(.semibold)
    }
    .foregroundColor(.white)
    .padding(.horizontal, Spacing.xl)
    .frame(maxWidth: .infinity)
    .frame(height: 52)
    .background(Color.semanticSuccess)
    .cornerRadius(Radius.full)
  }
}
