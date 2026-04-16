import AVKit
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
        Color.backgroundPrimary.edgesIgnoringSafeArea(.all)

        ScrollView {
          VStack(spacing: Spacing.screenPadding) {
            // Recording info card
            VStack(spacing: Spacing.xl) {
              Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundColor(.appPrimary)

              Text("Expert Recording")
                .font(.retraceTitle2)
                .fontWeight(.bold)
                .foregroundColor(.textPrimary)

              HStack(spacing: Spacing.screenPadding) {
                InfoItem(label: "Duration", value: formattedDuration)
                InfoItem(label: "Size", value: fileSize)
              }
            }
            .padding(Spacing.screenPadding)
            .background(Color.surfaceBase)
            .cornerRadius(Radius.lg)
            .overlay(
              RoundedRectangle(cornerRadius: Radius.lg)
                .stroke(Color.borderSubtle, lineWidth: 1)
            )

            // Upload state
            if uploadService.isUploading {
              VStack(spacing: Spacing.lg) {
                Text("Uploading...")
                  .foregroundColor(.textSecondary)

                ProgressView(value: uploadService.uploadProgress)
                  .tint(.appPrimary)

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
                  .tint(.appPrimary)

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
              .overlay(
                RoundedRectangle(cornerRadius: Radius.lg)
                  .stroke(Color.borderSubtle, lineWidth: 1)
              )
            }

            // Error
            if let error = uploadService.uploadError {
              Text(error)
                .font(.retraceCallout)
                .foregroundColor(.semanticError)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            }

            // Result
            if let result = uploadService.uploadResult {
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
              CustomButton(
                title: "Done",
                style: .primary,
                isDisabled: false
              ) {
                onDismiss()
              }
            }
          }
          .padding(Spacing.screenPadding)
        }
      }
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
        .font(.retraceTitle3)
        .fontWeight(.bold)
        .foregroundColor(.textPrimary)

      Text(procedure.description)
        .font(.retraceCallout)
        .foregroundColor(.textSecondary)

      Divider().background(Color.borderSubtle)

      Text("\(procedure.steps.count) Steps")
        .font(.retraceCallout)
        .fontWeight(.semibold)
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
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
  }
}

// MARK: - Step Detail View

struct StepDetailView: View {
  let step: ProcedureStepResponse
  let isExpanded: Bool
  let serverBaseURL: String
  let onTap: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onTap) {
        HStack(alignment: .top, spacing: Spacing.md) {
          Text("\(step.stepNumber).")
            .font(.retraceCallout)
            .fontWeight(.semibold)
            .foregroundColor(.appPrimary)
            .frame(width: 24, alignment: .trailing)

          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(step.title)
              .font(.retraceCallout)
              .fontWeight(.medium)
              .foregroundColor(.textPrimary)
              .multilineTextAlignment(.leading)

            Text(formatTimestamp(step.timestampStart) + " \u{2013} " + formatTimestamp(step.timestampEnd))
              .font(.system(size: 11, design: .monospaced))
              .foregroundColor(.textTertiary)
          }

          Spacer()

          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 11))
            .foregroundColor(.textTertiary)
        }
      }

      if isExpanded {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          Text(step.description)
            .font(.retraceSubheadline)
            .foregroundColor(.textSecondary)
            .padding(.top, Spacing.md)

          if let clipUrl = step.clipUrl,
             let url = URL(string: "\(serverBaseURL)\(clipUrl)") {
            StepClipPlayer(url: url)
          }

          if !step.tips.isEmpty {
            TagSection(title: "Tips", items: step.tips, color: .semanticInfo)
          }

          if !step.warnings.isEmpty {
            TagSection(title: "Warnings", items: step.warnings, color: .appPrimary)
          }
        }
        .padding(.leading, 32)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(.vertical, Spacing.md)
  }

  private func formatTimestamp(_ seconds: Double) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
  }
}

// MARK: - Step Clip Player

struct StepClipPlayer: View {
  let url: URL
  @State private var player: AVPlayer?

  var body: some View {
    Group {
      if let player {
        VideoPlayer(player: player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .cornerRadius(Radius.sm)
      } else {
        RoundedRectangle(cornerRadius: Radius.sm)
          .fill(Color.surfaceRaised)
          .aspectRatio(16 / 9, contentMode: .fit)
          .overlay {
            Button {
              let p = AVPlayer(url: url)
              player = p
              p.play()
            } label: {
              Image(systemName: "play.circle.fill")
                .font(.system(size: 36))
                .foregroundColor(.textPrimary.opacity(0.8))
            }
          }
      }
    }
  }
}

// MARK: - Tag Section

struct TagSection: View {
  let title: String
  let items: [String]
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text(title)
        .font(.retraceOverline)
        .foregroundColor(color)
        .textCase(.uppercase)

      FlowLayout(spacing: Spacing.sm) {
        ForEach(items, id: \.self) { item in
          Text(item)
            .font(.retraceCaption1)
            .foregroundColor(color)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(color.opacity(0.15))
            .cornerRadius(Radius.sm)
        }
      }
    }
  }
}

// MARK: - Flow Layout (wrapping tags)

struct FlowLayout: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let result = arrangeSubviews(proposal: proposal, subviews: subviews)
    return result.size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = arrangeSubviews(proposal: proposal, subviews: subviews)
    for (index, position) in result.positions.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
        proposal: ProposedViewSize(subviews[index].sizeThatFits(.unspecified))
      )
    }
  }

  private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
    let maxWidth = proposal.width ?? .infinity
    var positions: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > maxWidth && x > 0 {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      positions.append(CGPoint(x: x, y: y))
      rowHeight = max(rowHeight, size.height)
      x += size.width + spacing
      totalHeight = y + rowHeight
    }

    return (positions, CGSize(width: maxWidth, height: totalHeight))
  }
}
