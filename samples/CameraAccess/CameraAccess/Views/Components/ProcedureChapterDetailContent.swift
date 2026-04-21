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

  var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        ProcedureSourcePlayerCard(
          player: playerModel.player,
          summary: playerSummary,
          height: playerHeight(for: proxy.size)
        )

        ScrollViewReader { scrollProxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xl) {
              contentHeader
              stepSection(scrollProxy: scrollProxy)
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
  }

  private var contentHeader: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      VStack(alignment: .leading, spacing: Spacing.md) {
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
  let isExpanded: Bool
  let isActive: Bool
  let onTap: () -> Void
  let footer: Footer

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onTap) {
        HStack(alignment: .top, spacing: Spacing.lg) {
          stepBadge

          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(step.title)
              .font(.retraceFace(.medium, size: 16))
              .foregroundColor(.textPrimary)
              .multilineTextAlignment(.leading)

            Text(step.formattedTimeRange)
              .font(.system(size: 11, design: .monospaced))
              .foregroundColor(.textTertiary)
          }

          Spacer(minLength: 0)

          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.textTertiary)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .contentShape(Rectangle())

      if isExpanded {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          Text(step.description)
            .font(.retraceSubheadline)
            .foregroundColor(.textSecondary)

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
