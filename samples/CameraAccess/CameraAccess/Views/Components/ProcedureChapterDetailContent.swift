import AVKit
import SwiftUI

struct ProcedureMetricItem: Identifiable, Hashable {
  let icon: String
  let text: String

  var id: String { "\(icon)-\(text)" }

  static func workflowSummary(
    duration: Double,
    stepCount: Int,
    completionCount: Int
  ) -> [ProcedureMetricItem] {
    [
      ProcedureMetricItem(icon: "clock", text: ProcedureDisplayFormat.timestamp(duration)),
      ProcedureMetricItem(icon: "list.number", text: "\(stepCount)"),
      ProcedureMetricItem(icon: "checkmark.circle", text: "\(completionCount)"),
    ]
  }
}

struct ProcedureChapterDetailContent<ReadMoreContent: View, HeaderActionContent: View, ExpandedStepFooter: View>: View {
  let procedure: ProcedureResponse
  let serverBaseURL: String
  let metrics: [ProcedureMetricItem]
  let readMoreContent: ReadMoreContent
  let headerActionContent: HeaderActionContent
  let expandedStepFooter: (ProcedureStepResponse) -> ExpandedStepFooter

  @StateObject private var playerModel = ProcedureChapterPlayerModel()
  @State private var expandedStepNumber: Int?
  @State private var isDescriptionExpanded = false
  // Drives the in-app SFSafariViewController sheet when the user taps a
  // source row in the optional "Sources" footer. Identifiable URL +
  // .sheet(item:) gives us animated mount/unmount per URL change.
  @State private var selectedSourceURL: IdentifiableURL?

  private var playbackSignature: String {
    let stepSignature = procedure.orderedSteps.map {
      "\($0.stepNumber)-\($0.timestampStart)-\($0.timestampEnd)-\($0.title)"
    }.joined(separator: "|")
    return "\(procedure.id)-\(procedure.sourceVideo ?? "")-\(stepSignature)"
  }

  private var playerSummary: ProcedurePlaybackSummary? {
    guard playerModel.sourceVideoURL != nil else { return nil }
    return playerModel.playbackSummary
  }

  /// Procedures with `source_type` of "manual" or "web" have no real
  /// video — the player slot would either show a broken image (manual,
  /// where clip_url points at a PNG) or an empty fallback (web). Hide
  /// the player entirely for those and surface the source type via the
  /// small badge in `contentHeader` instead.
  private var hasPlayableVideo: Bool {
    let st = (procedure.sourceType ?? "video").lowercased()
    return st == "video"
  }

  var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        if hasPlayableVideo {
          ProcedureSourcePlayerCard(
            player: playerModel.player,
            summary: playerSummary,
            height: playerHeight(for: proxy.size)
          )
        }

        ScrollViewReader { scrollProxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xl) {
              contentHeader
              stepSection(scrollProxy: scrollProxy)
              sourcesSection
          }
          .padding(Spacing.screenPadding)
          .padding(.top, Spacing.md)
          .padding(.bottom, Spacing.jumbo)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
      }
    }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .task(id: playbackSignature) {
      playerModel.configure(procedure: procedure, serverBaseURL: serverBaseURL)
    }
    .onDisappear {
      playerModel.pause()
      playerModel.endPlaybackSession()
    }
    .sheet(item: $selectedSourceURL) { wrapper in
      SafariBrowserView(url: wrapper.url)
        .ignoresSafeArea()
    }
  }

  /// Source-type chip rendered above the title for manual/web procedures.
  /// Replaces the role the video card used to play in telling the user
  /// "where this procedure came from". Hidden for video procedures (the
  /// player itself is the cue).
  @ViewBuilder
  private var sourceTypeBadge: some View {
    let st = (procedure.sourceType ?? "video").lowercased()
    let info: (icon: String, text: String)? = {
      switch st {
      case "manual":
        return ("doc.fill", "Imported from manual")
      case "web":
        let n = procedure.sources?.count ?? 0
        let label = n == 1 ? "1 online source" : "\(n) online sources"
        return ("globe", "Synthesized from \(label)")
      default:
        return nil
      }
    }()
    if let info {
      HStack(spacing: Spacing.sm) {
        Image(systemName: info.icon)
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(.textSecondary)
        Text(info.text)
          .font(.retraceFace(.semibold, size: 12))
          .foregroundColor(.textSecondary)
          .tracking(0.3)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.sm)
      .background(Color.surfaceRaised)
      .clipShape(Capsule())
      .overlay(Capsule().stroke(Color.borderSubtle, lineWidth: 1))
    }
  }

  private var contentHeader: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        sourceTypeBadge

        Text(procedure.title)
          .font(.retraceTitle2)
          .foregroundColor(.textPrimary)

        ViewThatFits(in: .horizontal) {
          HStack(spacing: Spacing.sm) {
            ForEach(metrics) { metric in
              ProcedureMetricPill(metric: metric)
            }
            Spacer(minLength: 0)
          }

          VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
              ForEach(Array(metrics.prefix(2))) { metric in
                ProcedureMetricPill(metric: metric)
              }
            }

            if let metric = metrics.last {
              ProcedureMetricPill(metric: metric)
            }
          }
        }
      }

      descriptionSection
      headerActionContent

      if isDescriptionExpanded {
        readMoreContent
          .transition(.opacity)
      }
    }
  }

  @ViewBuilder
  private var descriptionSection: some View {
    let preview = ProcedureDescriptionPreview(description: procedure.description)

    if preview.isTruncatable {
      Button {
        withAnimation(.easeInOut(duration: 0.2)) {
          isDescriptionExpanded.toggle()
        }
      } label: {
        (
          Text(preview.visibleText(isExpanded: isDescriptionExpanded))
            .font(.retraceCallout)
            .foregroundColor(.textSecondary)
          + Text(isDescriptionExpanded ? " Show less" : "Read more")
            .font(.retraceCallout)
            .foregroundColor(.textPrimary)
            .bold()
            .italic()
        )
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("procedure_read_more_button")
    } else {
      Text(preview.fullText)
        .font(.retraceCallout)
        .foregroundColor(.textSecondary)
    }
  }

  private func stepSection(scrollProxy: ScrollViewProxy) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack {
        Text("STEPS")
          .font(.retraceOverline)
          .tracking(0.5)
          .foregroundColor(.textSecondary)

        Spacer()

        Text("\(procedure.steps.count)")
          .font(.retraceOverline)
          .foregroundColor(.textSecondary)
      }

      ForEach(procedure.orderedSteps) { step in
        ProcedureStepChapterRow(
          step: step,
          sourceType: procedure.sourceType,
          serverBaseURL: serverBaseURL,
          isExpanded: expandedStepNumber == step.stepNumber,
          isActive: playerModel.activeStepNumber == step.stepNumber,
          onTap: {
            handleStepTap(step, scrollProxy: scrollProxy)
          },
          footer: expandedStepFooter(step)
        )
        .id(step.stepNumber)
      }
    }
  }

  /// "Sources" footer — only renders for procedures the troubleshoot
  /// web-search flow built (`source_type='web'`), where Gemini cited a
  /// list of online sources. Hidden entirely for video- or
  /// manual-derived procedures so the layout stays unchanged for those.
  @ViewBuilder
  private var sourcesSection: some View {
    if let sources = procedure.sources, !sources.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack {
          Text("SOURCES")
            .font(.retraceOverline)
            .tracking(0.5)
            .foregroundColor(.textSecondary)

          Spacer()

          Text("\(sources.count)")
            .font(.retraceOverline)
            .foregroundColor(.textSecondary)
        }

        ForEach(sources) { source in
          SourceRow(source: source) {
            if let url = URL(string: source.url) {
              selectedSourceURL = IdentifiableURL(url: url)
            }
          }
        }
      }
    }
  }

  private func playerHeight(for size: CGSize) -> CGFloat {
    let maxHeight = min(size.height * 0.38, 320)
    let widthDrivenHeight = size.width * 9.0 / 16.0
    return max(220, min(widthDrivenHeight, maxHeight))
  }

  private func handleStepTap(_ step: ProcedureStepResponse, scrollProxy: ScrollViewProxy) {
    withAnimation(.easeInOut(duration: 0.2)) {
      expandedStepNumber = expandedStepNumber == step.stepNumber ? nil : step.stepNumber
    }

    playerModel.playStep(step)

    withAnimation(.easeInOut(duration: 0.25)) {
      scrollProxy.scrollTo(step.stepNumber, anchor: .center)
    }
  }
}

struct ProcedureMetricPill: View {
  let metric: ProcedureMetricItem

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: metric.icon)
        .font(.system(size: 10))

      Text(metric.text)
        .font(.retraceCaption1)
        .monospacedDigit()
    }
    .foregroundColor(.textSecondary)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .background(Color.surfaceBase)
    .cornerRadius(Radius.sm)
  }
}

struct ProcedureSourcePlayerCard: View {
  let player: AVPlayer?
  let summary: ProcedurePlaybackSummary?
  let height: CGFloat

  var body: some View {
    Group {
      if let player {
        VideoPlayer(player: player)
          .accessibilityIdentifier("procedure_top_player")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.black)
      } else {
        unavailableState
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: height)
    .background(Color.black)
    .clipped()
    .overlay(alignment: .topTrailing) {
      if let summary {
        ProcedureActiveStepSummary(summary: summary)
          .padding(Spacing.lg)
          .allowsHitTesting(false)
      }
    }
  }

  private var unavailableState: some View {
    VStack(spacing: Spacing.md) {
      Image(systemName: "video.slash")
        .font(.system(size: 28))
        .foregroundColor(.textSecondary)

      Text("Source video unavailable")
        .font(.retraceHeadline)
        .foregroundColor(.textPrimary)

      Text("Step details still work below, but timeline playback is unavailable on this recording.")
        .font(.retraceSubheadline)
        .foregroundColor(.textSecondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.screenPadding)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Spacing.screenPadding)
    .background(Color.surfaceBase)
  }
}

struct ProcedureActiveStepSummary: View {
  let summary: ProcedurePlaybackSummary

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: summary.symbolName)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(summary.style == .primary ? .appPrimary : .textSecondary)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 2) {
        Text(summary.title)
          .font(.retraceCaption1)
          .foregroundColor(.white)
          .lineLimit(2)

        if let subtitle = summary.subtitle {
          Text(subtitle)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white.opacity(0.75))
            .lineLimit(1)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .frame(maxWidth: 230, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.md))
    .overlay {
      RoundedRectangle(cornerRadius: Radius.md)
        .stroke(Color.white.opacity(0.14), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
    .accessibilityIdentifier("procedure_active_step_summary")
  }
}

struct ProcedureStepChapterRow<Footer: View>: View {
  let step: ProcedureStepResponse
  /// Procedure-level source type ("video" / "manual" / "web"). Drives
  /// whether the row shows the placeholder timestamp range and whether
  /// the expanded section embeds a PDF page image (for "manual"). Nil is
  /// treated as "video" for backward compatibility with legacy rows.
  let sourceType: String?
  let serverBaseURL: String
  let isExpanded: Bool
  let isActive: Bool
  let onTap: () -> Void
  let footer: Footer

  /// "video" rows keep their per-step timestamp range; "manual" and
  /// "web" timestamps are 30s placeholders and would mislead the user.
  private var showsTimestamp: Bool {
    (sourceType ?? "video").lowercased() == "video"
  }

  /// Manual procedures store the per-step PDF page render in `clip_url`
  /// (.png). When the step is expanded, we want it inline so the learner
  /// can see what the manual showed for this step.
  private var inlineManualImageURL: URL? {
    guard (sourceType ?? "video").lowercased() == "manual" else { return nil }
    guard let path = step.clipUrl, !path.isEmpty else { return nil }
    let lower = path.lowercased()
    let isImage = lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
    guard isImage else { return nil }
    return URL(string: "\(serverBaseURL)\(path)")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: Spacing.lg) {
        stepBadge

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(step.title)
            .font(.retraceFace(.medium, size: 16))
            .foregroundColor(.textPrimary)
            .multilineTextAlignment(.leading)

          if showsTimestamp {
            Text(step.formattedTimeRange)
              .font(.system(size: 11, design: .monospaced))
              .foregroundColor(.textTertiary)
          }
        }

        Spacer(minLength: 0)

        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(.textTertiary)
          .padding(.top, 2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if isExpanded {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          Text(step.description)
            .font(.retraceSubheadline)
            .foregroundColor(.textSecondary)

          if let imageURL = inlineManualImageURL {
            AsyncImage(url: imageURL) { phase in
              switch phase {
              case .success(let image):
                image.resizable().aspectRatio(contentMode: .fit)
              case .failure:
                Color.surfaceRaised.overlay(
                  Image(systemName: "doc.fill")
                    .foregroundColor(.textSecondary)
                )
              case .empty:
                Color.surfaceRaised.overlay(ProgressView())
              @unknown default:
                Color.surfaceRaised
              }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
              RoundedRectangle(cornerRadius: Radius.md)
                .stroke(Color.borderSubtle, lineWidth: 1)
            )
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

          footer
        }
        .padding(.leading, 50)
        .padding(.top, Spacing.lg)
        .transition(.opacity)
      }
    }
    .padding(Spacing.xl)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(rowBackground)
    .overlay {
      RoundedRectangle(cornerRadius: Radius.lg)
        .stroke(isActive ? Color.appPrimary.opacity(0.55) : Color.clear, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
    .contentShape(Rectangle())
    .onTapGesture {
      onTap()
    }
    .accessibilityIdentifier("procedure_step_row_\(step.stepNumber)")
  }

  private var rowBackground: Color {
    if isActive {
      return Color.appPrimary.opacity(0.14)
    }
    if isExpanded {
      return .surfaceRaised
    }
    return .surfaceBase
  }

  private var stepBadge: some View {
    ZStack {
      Circle()
        .fill(isActive ? Color.appPrimary : Color.surfaceRaised)

      if isActive {
        Image(systemName: "play.fill")
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(.backgroundPrimary)
      } else {
        Text("\(step.stepNumber)")
          .font(.retraceCaption1)
          .fontWeight(.semibold)
          .foregroundColor(.textPrimary)
      }
    }
    .frame(width: 30, height: 30)
  }
}
