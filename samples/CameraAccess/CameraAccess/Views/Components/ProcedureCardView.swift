import SwiftUI
import UIKit

struct ProcedureCardView: View {
  let title: String
  let description: String
  let stepCount: Int
  let duration: Double
  let createdAt: String
  let status: String?
  let iconSymbol: String?
  let iconEmoji: String?
  /// "video" | "manual" | "web" | nil. Drives the processing-state copy
  /// and badge symbol. Optional so older server builds still compile.
  let sourceType: String?
  /// Procedure-level error message, surfaced on the failed-state card.
  let errorMessage: String?

  /// Drives the badge pulse animation when status == "processing".
  /// Toggled once in `.onAppear`; the `.repeatForever` modifier on
  /// `.animation` carries the rest. We never write @State on a polling
  /// timer — see the live-elapsed pill, which uses TimelineView.
  @State private var pulseTrigger: Bool = false

  init(
    title: String,
    description: String,
    stepCount: Int,
    duration: Double,
    createdAt: String,
    status: String?,
    iconSymbol: String? = nil,
    iconEmoji: String? = nil,
    sourceType: String? = nil,
    errorMessage: String? = nil
  ) {
    self.title = title
    self.description = description
    self.stepCount = stepCount
    self.duration = duration
    self.createdAt = createdAt
    self.status = status
    self.iconSymbol = iconSymbol
    self.iconEmoji = iconEmoji
    self.sourceType = sourceType
    self.errorMessage = errorMessage
  }

  var body: some View {
    HStack(spacing: Spacing.xl) {
      statusBadge
        .frame(width: 40, height: 40)

      // .id(status) lets SwiftUI re-identity this subtree when the status
      // flips (e.g. "processing" → "completed"), so the transition fires
      // and the card animates the swap-in instead of silently mutating.
      contentColumn
        .id(status ?? "completed")
        .transition(
          .opacity.combined(
            with: .scale(scale: 0.97, anchor: .center)
          )
        )

      Spacer(minLength: 0)

      // Chevron is hidden during processing/failed — its absence at the
      // trailing edge is the visual cue that this row doesn't navigate.
      // We keep a clear spacer so the text column doesn't widen and jolt.
      if isProcessing || isFailed {
        Color.clear.frame(width: 10)
      } else {
        Image(systemName: "chevron.right")
          .font(.retraceSubheadline)
          .foregroundColor(.textTertiary)
      }
    }
    .padding(Spacing.xxl)
    .background(Color.surfaceBase)
    .cornerRadius(Radius.lg)
    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: status)
  }

  // MARK: - State predicates

  private var isProcessing: Bool { status == "processing" }
  private var isFailed: Bool { status == "failed" }
  private var isCompletedPartial: Bool { status == "completed_partial" }

  // MARK: - Inner content (state-dependent)

  @ViewBuilder
  private var contentColumn: some View {
    if isProcessing {
      processingContent
    } else if isFailed {
      failedContent
    } else {
      completedContent
    }
  }

  @ViewBuilder
  private var completedContent: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text(title)
        .font(.retraceHeadline)
        .foregroundColor(.textPrimary)
        .lineLimit(1)

      Text(description)
        .font(.retraceSubheadline)
        .foregroundColor(.textSecondary)
        .lineLimit(2)

      HStack(spacing: Spacing.md) {
        MetadataPill(icon: "clock", text: formattedDuration)
        // completed_partial gets a subtle warning trailing the step pill
        // — same shape as a normal step pill so layout doesn't shift.
        if isCompletedPartial {
          HStack(spacing: 4) {
            MetadataPill(icon: "list.number", text: "\(stepCount) steps")
            Image(systemName: "exclamationmark.triangle")
              .font(.system(size: 12))
              .foregroundColor(.textTertiary)
          }
        } else {
          MetadataPill(icon: "list.number", text: "\(stepCount) steps")
        }
      }
    }
  }

  @ViewBuilder
  private var processingContent: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text(processingTitleCopy)
        .font(.retraceHeadline)
        .foregroundColor(.textPrimary)
        .lineLimit(1)

      // Description swaps to "taking longer than usual" once we've blown
      // past the per-source-type expectation. Driven from inside a
      // TimelineView so the description re-evaluates on the same clock
      // as the elapsed pill — no @State writes per second.
      TimelineView(.periodic(from: .now, by: 1.0)) { context in
        let elapsed = elapsedSeconds(asOf: context.date)
        Text(processingDescriptionCopy(elapsed: elapsed))
          .font(.retraceSubheadline)
          .foregroundColor(.textSecondary)
          .lineLimit(2)
      }

      HStack(spacing: Spacing.md) {
        // Live elapsed pill — TimelineView re-renders only this closure on
        // each tick, not the whole card. Pure SwiftUI / Core-Animation
        // path, no Timer.publish + @State write loop.
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
          MetadataPill(
            icon: "clock",
            text: "\(formatElapsed(elapsedSeconds(asOf: context.date))) elapsed"
          )
        }
        MetadataPill(icon: nil, text: "Analyzing…")
      }
    }
  }

  @ViewBuilder
  private var failedContent: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Processing failed")
        .font(.retraceHeadline)
        .foregroundColor(.textPrimary)
        .lineLimit(1)

      Text(failedDescriptionCopy)
        .font(.retraceSubheadline)
        .foregroundColor(.textSecondary)
        .lineLimit(2)

      HStack(spacing: Spacing.md) {
        MetadataPill(icon: nil, text: "Failed")
      }
    }
  }

  // MARK: - Status badge

  @ViewBuilder
  private var statusBadge: some View {
    if isProcessing {
      processingBadge
    } else if isFailed {
      failedBadge
    } else {
      Circle()
        .fill(Color.surfaceRaised)
        .overlay(iconContent)
    }
  }

  @ViewBuilder
  private var processingBadge: some View {
    Circle()
      .fill(Color.iconSurface)
      .overlay(
        Image(systemName: processingBadgeSymbol)
          .resizable()
          .renderingMode(.template)
          .scaledToFit()
          .foregroundColor(.textSecondary)
          .frame(width: 18, height: 18)
          .opacity(pulseTrigger ? 1.0 : 0.4)
          .animation(
            .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
            value: pulseTrigger
          )
      )
      .onAppear { pulseTrigger = true }
  }

  @ViewBuilder
  private var failedBadge: some View {
    Circle()
      .fill(Color.iconSurface)
      .overlay(
        Image(systemName: "exclamationmark.circle")
          .resizable()
          .renderingMode(.template)
          .scaledToFit()
          .foregroundColor(.textSecondary)
          .frame(width: 18, height: 18)
      )
  }

  /// Always-white branded icon. The server returns a `lucide:wrench` PNG
  /// transparently when the picked Iconify ID 404s, so we never need a
  /// colored emoji on this badge — emojis aren't tintable on iOS (Apple
  /// Color Emoji is a bitmap font), so they'd break the white-only design.
  /// Only when the entire icon URL fails to load (e.g. server unreachable)
  /// do we fall through to the step count as a defensive last resort.
  @ViewBuilder
  private var iconContent: some View {
    CachedAsyncImage(url: iconURL) { phase in
      switch phase {
      case .success(let image):
        image
          .resizable()
          .renderingMode(.template)
          .scaledToFit()
          .foregroundColor(.textPrimary)
          .frame(width: 22, height: 22)
      case .empty, .failure:
        // .empty: brief loading flicker — render nothing (server PNG arrives fast).
        // .failure: only when the server itself is unreachable; show step count
        //           rather than a colored emoji that would break branding.
        if case .failure = phase {
          stepCountFallback
        } else {
          Color.clear
        }
      @unknown default:
        stepCountFallback
      }
    }
  }

  @ViewBuilder
  private var stepCountFallback: some View {
    Text("\(stepCount)")
      .font(Font.retraceHeadline)
      .fontWeight(.bold)
      .foregroundColor(.textPrimary)
  }

  // MARK: - Source-type-aware copy

  private var processingTitleCopy: String {
    switch sourceType {
    case "video": return "Analyzing video…"
    case "manual": return "Reading manual…"
    default: return "Analyzing…"
    }
  }

  private func processingDescriptionCopy(elapsed: Int) -> String {
    let overEstimateThreshold: Int
    switch sourceType {
    case "video":  overEstimateThreshold = 90
    case "manual": overEstimateThreshold = 60
    default:       overEstimateThreshold = 90
    }
    if elapsed > overEstimateThreshold {
      return "Taking longer than usual — Gemini is still working"
    }
    switch sourceType {
    case "video":
      return "Gemini is reading the recording — usually 60–90s"
    case "manual":
      return "Gemini is reading the PDF — usually 30–60s"
    default:
      return "Gemini is extracting the procedure — usually 60–90s"
    }
  }

  private var processingBadgeSymbol: String {
    switch sourceType {
    case "video": return "video.badge.waveform"
    case "manual": return "doc.text"
    default: return "sparkles"
    }
  }

  private var failedDescriptionCopy: String {
    let trimmed = (errorMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return "Something went wrong — delete and try again"
    }
    // First sentence (or first 60 chars), whichever shorter.
    let firstSentence = trimmed.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? trimmed
    return String(firstSentence.prefix(60))
  }

  // MARK: - Elapsed-time helpers

  /// Parse `createdAt` once per evaluation and return a fresh Date
  /// difference. Server sends ISO8601 with millisecond precision (3 frac
  /// digits). Returns 0 if parse fails — the pill just shows 0:00 elapsed.
  private func elapsedSeconds(asOf now: Date) -> Int {
    guard let createdDate = Self.iso8601.date(from: createdAt) else { return 0 }
    return max(0, Int(now.timeIntervalSince(createdDate)))
  }

  private func formatElapsed(_ seconds: Int) -> String {
    let mins = seconds / 60
    let secs = seconds % 60
    return String(format: "%d:%02d", mins, secs)
  }

  /// Static formatter — initialized once per app run, not per render.
  private static let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  // MARK: - Icon URL

  /// Builds the server-side icon endpoint URL. If `iconSymbol` parses as a
  /// valid Iconify ID (`prefix:name`), use it directly. Otherwise request
  /// the generic `lucide:wrench` fallback so the badge always renders a
  /// branded white icon — never a colored emoji.
  private var iconURL: URL? {
    let base = ServerEndpoint.shared.resolvedBaseURL
    if let (prefix, name) = parsedIconID {
      return URL(string: "\(base)/api/icons/\(prefix)/\(name).png")
    }
    return URL(string: "\(base)/api/icons/lucide/wrench.png")
  }

  private var parsedIconID: (String, String)? {
    guard let symbol = iconSymbol, !symbol.isEmpty else { return nil }
    let parts = symbol.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
    guard parts.count == 2 else { return nil }
    let prefix = String(parts[0])
    let name = String(parts[1])
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
    guard !prefix.isEmpty,
          !name.isEmpty,
          prefix.unicodeScalars.allSatisfy({ allowed.contains($0) }),
          name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      return nil
    }
    return (prefix, name)
  }

  private var formattedDuration: String {
    let mins = Int(duration) / 60
    let secs = Int(duration) % 60
    return String(format: "%d:%02d", mins, secs)
  }
}
