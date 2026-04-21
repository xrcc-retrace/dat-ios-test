import AVFoundation
import AVKit
import SwiftUI

enum ProcedureDisplayFormat {
  private static let internetDateFormatterWithFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let internetDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static let mediumDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    return formatter
  }()

  static func timestamp(_ seconds: Double) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
  }

  static func timeRange(start: Double, end: Double) -> String {
    timestamp(start) + " \u{2013} " + timestamp(end)
  }

  static func date(_ isoString: String) -> String {
    if let date = internetDateFormatterWithFractionalSeconds.date(from: isoString)
      ?? internetDateFormatter.date(from: isoString) {
      return mediumDateFormatter.string(from: date)
    }

    return isoString
  }
}

struct ProcedureDescriptionPreview: Equatable {
  static let collapsedCharacterLimit = 90

  let fullText: String
  let collapsedText: String?

  var isTruncatable: Bool {
    collapsedText != nil
  }

  init(description: String, characterLimit: Int = collapsedCharacterLimit) {
    fullText = description

    guard description.count > characterLimit else {
      collapsedText = nil
      return
    }

    let limitIndex = description.index(description.startIndex, offsetBy: characterLimit)
    let slice = String(description[..<limitIndex])
    let nextCharacter = description[limitIndex]
    var previewText = slice.trimmingCharacters(in: .whitespacesAndNewlines)

    let cutThroughWord = (slice.last?.isWhitespace == false) && !nextCharacter.isWhitespace
    if cutThroughWord,
       let lastWhitespace = previewText.lastIndex(where: { $0.isWhitespace }) {
      let wordSafeSlice = previewText[..<lastWhitespace]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !wordSafeSlice.isEmpty {
        previewText = wordSafeSlice
      }
    }

    collapsedText = previewText + "… "
  }

  func visibleText(isExpanded: Bool) -> String {
    guard let collapsedText, !isExpanded else { return fullText }
    return collapsedText
  }
}

extension ProcedureStepResponse {
  var formattedTimeRange: String {
    ProcedureDisplayFormat.timeRange(start: timestampStart, end: timestampEnd)
  }
}

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
            .font(.retraceFace(.semibold, size: 16))
            .foregroundColor(.textPrimary)
            .frame(width: 24, alignment: .trailing)

          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(step.title)
              .font(.retraceFace(.medium, size: 16))
              .foregroundColor(.textPrimary)
              .multilineTextAlignment(.leading)

            Text(step.formattedTimeRange)
              .font(.system(size: 11, design: .monospaced))
              .foregroundColor(.textTertiary)
          }

          Spacer()

          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 11))
            .foregroundColor(.textTertiary)
        }
      }
      .buttonStyle(.plain)

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

          if !step.errorCriteria.isEmpty {
            TagSection(title: "Observable Errors", items: step.errorCriteria, color: .appPrimary)
          }
        }
        .padding(.leading, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
      }
    }
    .padding(.vertical, Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .clipped()
  }
}

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
              let player = AVPlayer(url: url)
              self.player = player
              player.play()
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
    .task(id: url) {
      aspectRatio = await loadVideoAspectRatio(for: url)
    }
  }
}

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

struct FlowLayout: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrangeSubviews(proposal: proposal, subviews: subviews).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let arrangement = arrangeSubviews(proposal: proposal, subviews: subviews)
    for (index, position) in arrangement.positions.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
        proposal: ProposedViewSize(subviews[index].sizeThatFits(.unspecified))
      )
    }
  }

  private func arrangeSubviews(
    proposal: ProposedViewSize,
    subviews: Subviews
  ) -> (positions: [CGPoint], size: CGSize) {
    let maxWidth = proposal.width ?? .infinity
    var positions: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    var maxRowExtent: CGFloat = 0

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
      maxRowExtent = max(maxRowExtent, x - spacing)
      totalHeight = y + rowHeight
    }

    let reportedWidth = proposal.width ?? maxRowExtent
    return (positions, CGSize(width: reportedWidth, height: totalHeight))
  }
}

private func loadVideoAspectRatio(for url: URL) async -> CGFloat? {
  let asset = AVURLAsset(url: url)
  guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
  guard let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }

  let transformedSize = size.applying(transform)
  let width = abs(transformedSize.width)
  let height = abs(transformedSize.height)

  guard width > 0, height > 0 else { return nil }
  return width / height
}
