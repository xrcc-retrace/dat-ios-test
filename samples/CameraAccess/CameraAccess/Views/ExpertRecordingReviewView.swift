import AVKit
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

// MARK: - Acknowledge Result Button

struct AcknowledgeResultButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "checkmark.circle.fill")
          .font(.retraceHeadline)
        Text("Everything is processed")
          .font(.retraceBody)
          .fontWeight(.semibold)
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

// MARK: - Adaptive Video Player

// Reads the asset's real display aspect ratio (applying preferredTransform) and
// applies it to the view's aspect modifier. Prevents layout ballooning when a
// landscape or square source is rendered in a view previously hardcoded to 9:16.
struct AdaptiveVideoPlayer: View {
  let url: URL
  let fallbackRatio: CGFloat
  let cornerRadius: CGFloat
  let playIconSize: CGFloat
  let playIconOpacity: Double

  @State private var player: AVPlayer?
  @State private var aspectRatio: CGFloat?

  var body: some View {
    Group {
      if let player {
        VideoPlayer(player: player)
      } else {
        VideoThumbnailView(url: url, cornerRadius: cornerRadius)
          .overlay {
            Button {
              let p = AVPlayer(url: url)
              player = p
              p.play()
            } label: {
              Image(systemName: "play.circle.fill")
                .font(.system(size: playIconSize))
                .foregroundColor(.textPrimary.opacity(playIconOpacity))
            }
          }
      }
    }
    .aspectRatio(aspectRatio ?? fallbackRatio, contentMode: .fit)
    .frame(maxHeight: 400)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    .frame(maxWidth: .infinity)
    .task(id: url) { await loadAspect() }
  }

  private func loadAspect() async {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
    guard let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return }
    let t = size.applying(transform)
    let w = abs(t.width)
    let h = abs(t.height)
    guard w > 0, h > 0 else { return }
    let ratio = w / h
    await MainActor.run { self.aspectRatio = ratio }
  }
}

// MARK: - Recording Preview Player

struct RecordingPreviewPlayer: View {
  let url: URL

  var body: some View {
    AdaptiveVideoPlayer(
      url: url,
      fallbackRatio: 9.0 / 16.0,
      cornerRadius: Radius.lg,
      playIconSize: 56,
      playIconOpacity: 0.85
    )
  }
}

// MARK: - Step Clip Player

struct StepClipPlayer: View {
  let url: URL

  var body: some View {
    AdaptiveVideoPlayer(
      url: url,
      fallbackRatio: 9.0 / 16.0,
      cornerRadius: Radius.sm,
      playIconSize: 36,
      playIconOpacity: 0.8
    )
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
