import SwiftUI

struct ExpertRecordingReviewView: View {
  let recordingURL: URL
  let duration: TimeInterval
  @ObservedObject var uploadService: UploadService
  let onDismiss: () -> Void
  var onAcknowledgeResult: (() -> Void)? = nil

  @State private var fileSize: String = ""
  @State private var hasAcknowledgedResult: Bool = false

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

            // Result — gated behind the acknowledgement tap so it doesn't pop in unannounced.
            if let result = uploadService.uploadResult, hasAcknowledgedResult {
              ProcedureSummaryView(procedure: result, serverBaseURL: uploadService.serverBaseURL)
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
            } else if uploadService.uploadResult != nil {
              if hasAcknowledgedResult {
                CustomButton(
                  title: "Done",
                  style: .primary,
                  isDisabled: false
                ) {
                  onDismiss()
                }
              } else {
                AcknowledgeResultButton {
                  withAnimation(.easeInOut(duration: 0.25)) {
                    hasAcknowledgedResult = true
                  }
                  onAcknowledgeResult?()
                }
              }
            }
          }
          .padding(Spacing.screenPadding)
        }
      }
      .navigationTitle("Review")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Close") { onDismiss() }
            .foregroundColor(.textSecondary)
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

struct ProcedureSummaryView: View {
  let procedure: ProcedureResponse
  let serverBaseURL: String

  @State private var expandedStep: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      HStack {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.semanticSuccess)
        Text("Procedure Generated")
          .font(.retraceHeadline)
          .foregroundColor(.textPrimary)
      }

      Text(procedure.title)
        .font(.retraceFace(.bold, size: 18))
        .foregroundColor(.textPrimary)

      Text(procedure.description)
        .font(.retraceCallout)
        .foregroundColor(.textSecondary)

      Divider().background(Color.borderSubtle)

      Text("\(procedure.steps.count) Steps")
        .font(.retraceFace(.semibold, size: 16))
        .foregroundColor(.textSecondary)

      ForEach(procedure.steps, id: \.stepNumber) { step in
        StepDetailView(
          step: step,
          isExpanded: expandedStep == step.stepNumber,
          serverBaseURL: serverBaseURL
        ) {
          withAnimation(.easeInOut(duration: 0.25)) {
            if expandedStep == step.stepNumber {
              expandedStep = nil
            } else {
              expandedStep = step.stepNumber
            }
          }
        }
      }
    }
    .padding(Spacing.xl)
    .background(Color.surfaceBase)
    .cornerRadius(Radius.md)
  }
}

// MARK: - Acknowledge Result Button

struct AcknowledgeResultButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "checkmark.circle.fill")
          .font(.retraceHeadline)
        Text("Everything is processed")
          .font(.retraceFace(.semibold, size: 17))
      }
      .foregroundColor(.white)
      .frame(maxWidth: .infinity)
      .frame(height: 52)
      .background(Color.semanticSuccess)
      .cornerRadius(Radius.full)
    }
    .buttonStyle(ScaleButtonStyle())
  }
}
