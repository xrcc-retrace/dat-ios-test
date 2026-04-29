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
        VStack(spacing: 0) {
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

                  Text("Generating procedure…")
                    .font(.retraceHeadline)
                    .foregroundColor(.textPrimary)

                  Text("Usually under a minute.")
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
            }
            .padding(Spacing.screenPadding)
          }
          .frame(maxHeight: .infinity)

          // Bottom-pinned action row, mirrors `ExpertManualUploadSheet`'s
          // layout (Spacer + actionRow). The action shown depends on
          // upload phase — see `actionRow`. During `isUploading` no row
          // is shown (the progress bar above carries the state); the
          // user has no intentional exit until upload completes, mirroring
          // the manual-import flow.
          actionRow
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.bottom, Spacing.section)
        }
      }
      .navigationTitle("Review")
      .navigationBarTitleDisplayMode(.inline)
      .retraceNavBar()
      // No toolbar X. Pre-upload, the bottom **Discard** button is the
      // only exit (close-the-screen and discard-the-recording are the
      // same intent — a separate X would be redundant). During upload
      // there's no exit (matches the manual-import flow). During
      // processing, **Keep working in the background** at the bottom is
      // the exit. After a result arrives, **Review workflow** is the
      // primary action; users who want to back out without reviewing can
      // switch tabs (the auto-pop will refire if they backgrounded it).
      .onAppear {
        loadFileSize()
      }
    }
  }

  /// Single bottom-pinned action row. Phase-driven so the layout matches
  /// `ExpertManualUploadSheet` — one button (or button stack) at the
  /// bottom of the screen, regardless of how much state is shown above.
  @ViewBuilder
  private var actionRow: some View {
    if let result = uploadService.uploadResult {
      // Result ready — primary action is to review the generated procedure.
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
    } else if uploadService.isProcessing {
      // Upload finished, server is generating. Mirror the manual sheet's
      // analyzing-phase affordance — one button, surfaceRaised pill,
      // bottom-pinned. Marks the upload as backgrounded so the
      // `ExpertTabView`-level auto-pop fires when the result lands.
      Button {
        uploadService.markBackgrounded()
        onDismiss()
      } label: {
        Text("Keep working in the background")
          .font(.retraceFace(.semibold, size: 16))
          .foregroundColor(.textPrimary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, Spacing.lg)
          .background(Color.surfaceRaised)
          .cornerRadius(Radius.md)
      }
    } else if !uploadService.isUploading {
      // Idle / pre-upload. Upload-to-Server + Discard. The Discard button
      // doubles as the close affordance — there is no toolbar X.
      VStack(spacing: Spacing.lg) {
        CustomButton(
          title: "Upload to Server",
          style: .primary,
          isDisabled: false
        ) {
          Task {
            await uploadService.uploadRecording(fileURL: recordingURL)
          }
        }

        CustomButton(
          title: "Discard",
          style: .destructive,
          isDisabled: false
        ) {
          try? FileManager.default.removeItem(at: recordingURL)
          onDismiss()
        }
      }
    }
    // During isUploading: no action row. Progress bar above carries state.
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
