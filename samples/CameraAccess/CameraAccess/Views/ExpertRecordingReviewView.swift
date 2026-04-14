import SwiftUI

struct ExpertRecordingReviewView: View {
  let recordingURL: URL
  let duration: TimeInterval
  @ObservedObject var uploadService: UploadService
  let onDismiss: () -> Void

  @State private var fileSize: String = ""

  var body: some View {
    NavigationStack {
      ZStack {
        Color.black.edgesIgnoringSafeArea(.all)

        VStack(spacing: 24) {
          // Recording info card
          VStack(spacing: 16) {
            Image(systemName: "film")
              .font(.system(size: 48))
              .foregroundColor(.appPrimary)

            Text("Expert Recording")
              .font(.system(size: 22, weight: .bold))
              .foregroundColor(.white)

            HStack(spacing: 24) {
              InfoItem(label: "Duration", value: formattedDuration)
              InfoItem(label: "Size", value: fileSize)
            }
          }
          .padding(24)
          .background(Color(.systemGray6).opacity(0.15))
          .cornerRadius(16)

          // Upload state
          if uploadService.isUploading {
            VStack(spacing: 12) {
              if uploadService.uploadProgress < 0.99 {
                Text("Uploading...")
                  .foregroundColor(.gray)
              } else {
                Text("Processing with AI...")
                  .foregroundColor(.gray)
              }

              ProgressView(value: uploadService.uploadProgress)
                .tint(.appPrimary)

              Text("\(Int(uploadService.uploadProgress * 100))%")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.gray)
            }
            .padding(.horizontal)
          }

          // Error
          if let error = uploadService.uploadError {
            Text(error)
              .font(.system(size: 14))
              .foregroundColor(.red)
              .multilineTextAlignment(.center)
              .padding(.horizontal)
          }

          // Result
          if let result = uploadService.uploadResult {
            ProcedureSummaryView(procedure: result)
          }

          Spacer()

          // Action buttons
          if uploadService.uploadResult == nil {
            VStack(spacing: 12) {
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
          } else {
            CustomButton(
              title: "Done",
              style: .primary,
              isDisabled: false
            ) {
              onDismiss()
            }
          }
        }
        .padding(24)
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Close") { onDismiss() }
            .foregroundColor(.white)
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
      fileSize = "—"
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
    VStack(spacing: 4) {
      Text(label)
        .font(.system(size: 12))
        .foregroundColor(.gray)
      Text(value)
        .font(.system(size: 18, weight: .semibold))
        .foregroundColor(.white)
    }
  }
}

struct ProcedureSummaryView: View {
  let procedure: ProcedureResponse

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.green)
        Text("Procedure Generated")
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(.white)
      }

      Text(procedure.title)
        .font(.system(size: 18, weight: .bold))
        .foregroundColor(.white)

      Text(procedure.description)
        .font(.system(size: 14))
        .foregroundColor(.gray)

      Divider().background(Color.gray.opacity(0.3))

      Text("\(procedure.steps.count) Steps")
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(.gray)

      ForEach(procedure.steps, id: \.stepNumber) { step in
        HStack(alignment: .top, spacing: 8) {
          Text("\(step.stepNumber).")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.appPrimary)
            .frame(width: 24, alignment: .trailing)
          Text(step.title)
            .font(.system(size: 14))
            .foregroundColor(.white)
        }
      }
    }
    .padding(16)
    .background(Color(.systemGray6).opacity(0.15))
    .cornerRadius(12)
  }
}
