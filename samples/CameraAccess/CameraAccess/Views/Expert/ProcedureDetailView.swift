import AVFoundation
import AVKit
import SwiftUI

struct ProcedureDetailView: View {
  let procedureId: String
  @StateObject private var viewModel = ProcedureDetailViewModel()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    RetraceScreen {
      content
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("Workflow")
    .retraceNavBar()
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          if let procedure = viewModel.procedure {
            NavigationLink {
              ProcedureEditView(procedure: procedure) {
                Task { await viewModel.fetchProcedure(id: procedureId) }
              }
            } label: {
              Label("Edit", systemImage: "pencil")
            }
          }
          Button(role: .destructive) {
            viewModel.showDeleteConfirmation = true
          } label: {
            Label("Delete", systemImage: "trash")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .foregroundColor(.textSecondary)
        }
      }
    }
    .alert("Delete Procedure", isPresented: $viewModel.showDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        Task {
          if await viewModel.deleteProcedure() {
            dismiss()
          }
        }
      }
    } message: {
      Text("This procedure and all its clips will be permanently deleted.")
    }
    .task {
      await viewModel.fetchProcedure(id: procedureId)
    }
  }

  @ViewBuilder
  private var content: some View {
    if viewModel.isLoading && viewModel.procedure == nil {
      ProgressView()
        .scaleEffect(1.5)
        .tint(.textPrimary)
    } else if let procedure = viewModel.procedure {
      ProcedureChapterDetailContent(
        procedure: procedure,
        serverBaseURL: viewModel.serverBaseURL,
        metrics: [
          ProcedureMetricItem(icon: "clock", text: ProcedureDisplayFormat.timestamp(procedure.totalDuration)),
          ProcedureMetricItem(icon: "list.number", text: "\(procedure.steps.count)"),
          ProcedureMetricItem(icon: "checkmark.circle", text: "\(placeholderCompletionCount)"),
        ],
        readMoreContent: AnyView(expertReadMoreContent(for: procedure)),
        headerActionContent: AnyView(EmptyView()),
        expandedStepFooter: { step in
          AnyView(expertStepFooter(for: step))
        }
      )
    } else if let error = viewModel.errorMessage {
      VStack(spacing: Spacing.lg) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 36))
          .foregroundColor(.textPrimary)
        Text(error)
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
          .multilineTextAlignment(.center)
      }
      .padding(Spacing.screenPadding)
    }
  }

  private var placeholderCompletionCount: Int {
    // Placeholder until procedure-level analytics are available from the backend.
    142
  }

  @ViewBuilder
  private func expertReadMoreContent(for procedure: ProcedureResponse) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Divider()
        .background(Color.borderSubtle)

      HStack(spacing: Spacing.md) {
        MetadataPill(icon: "calendar", text: ProcedureDisplayFormat.date(procedure.createdAt))

        if let status = procedure.status, !status.isEmpty {
          MetadataPill(icon: "sparkles", text: status.capitalized)
        }
      }

      Text("Use the overflow menu to edit the workflow, or jump into a step below to revise that section in place.")
        .font(.retraceSubheadline)
        .foregroundColor(.textSecondary)
    }
  }

  @ViewBuilder
  private func expertStepFooter(for step: ProcedureStepResponse) -> some View {
    HStack {
      Spacer()
      NavigationLink {
        StepEditView(
          procedureId: procedureId,
          step: step
        ) {
          Task { await viewModel.fetchProcedure(id: procedureId) }
        }
      } label: {
        Label("Edit step", systemImage: "pencil")
          .font(.retraceSubheadline)
          .foregroundColor(.textPrimary)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm)
          .background(Color.surfaceRaised)
          .clipShape(Capsule())
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

struct ProcedureMetricItem: Identifiable, Hashable {
  let icon: String
  let text: String

  var id: String { "\(icon)-\(text)" }
}

struct ProcedureChapterDetailContent: View {
  let procedure: ProcedureResponse
  let serverBaseURL: String
  let metrics: [ProcedureMetricItem]
  let readMoreContent: AnyView
  let headerActionContent: AnyView
  let expandedStepFooter: (ProcedureStepResponse) -> AnyView

  @StateObject private var playerModel = ProcedureChapterPlayerModel()
  @State private var expandedStepNumber: Int?
  @State private var isDescriptionExpanded = false

  private var playbackSignature: String {
    let stepSignature = procedure.steps.map {
      "\($0.stepNumber)-\($0.timestampStart)-\($0.timestampEnd)-\($0.title)"
    }.joined(separator: "|")
    return "\(procedure.id)-\(procedure.sourceVideo ?? "")-\(stepSignature)"
  }

  var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        ProcedureSourcePlayerCard(
          playerModel: playerModel,
          height: playerHeight(for: proxy.size)
        )

        ScrollViewReader { scrollProxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xl) {
              contentHeader

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

                ForEach(procedure.steps) { step in
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
            .padding(Spacing.screenPadding)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.jumbo)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
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
    VStack(alignment: .leading, spacing: Spacing.xl) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        Text(procedure.title)
          .font(.retraceTitle2)
          .foregroundColor(.textPrimary)

        ProcedureActiveStepSummary(playerModel: playerModel)

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

  private func playerHeight(for size: CGSize) -> CGFloat {
    let maxHeight = min(size.height * 0.38, 320)
    let widthDrivenHeight = size.width * 9.0 / 16.0
    return max(220, min(widthDrivenHeight, maxHeight))
  }

  private func handleStepTap(
    _ step: ProcedureStepResponse,
    scrollProxy: ScrollViewProxy
  ) {
    withAnimation(.easeInOut(duration: 0.2)) {
      if expandedStepNumber == step.stepNumber {
        expandedStepNumber = nil
      } else {
        expandedStepNumber = step.stepNumber
      }
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
  @ObservedObject var playerModel: ProcedureChapterPlayerModel
  let height: CGFloat

  var body: some View {
    Group {
      if let player = playerModel.player {
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
  @ObservedObject var playerModel: ProcedureChapterPlayerModel

  var body: some View {
    let summary = playerModel.activeStepSummary

    HStack(alignment: .center, spacing: Spacing.md) {
      Image(systemName: summary.icon)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(summary.iconColor)

      VStack(alignment: .leading, spacing: 2) {
        Text(summary.title)
          .font(.retraceCaption1)
          .foregroundColor(.textPrimary)
          .lineLimit(1)

        if let subtitle = summary.subtitle {
          Text(subtitle)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.textTertiary)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.surfaceBase)
    .cornerRadius(Radius.md)
    .accessibilityIdentifier("procedure_active_step_summary")
  }
}

struct ProcedureStepChapterRow: View {
  let step: ProcedureStepResponse
  let isExpanded: Bool
  let isActive: Bool
  let onTap: () -> Void
  let footer: AnyView

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

final class ProcedureChapterPlayerModel: ObservableObject {
  @Published private(set) var player: AVPlayer?
  @Published private(set) var sourceVideoURL: URL?
  @Published private(set) var activeStepNumber: Int?

  private let playbackAudioSession = WorkflowPlaybackAudioSession()
  private var steps: [ProcedureStepResponse] = []
  private var timeObserverToken: Any?

  deinit {
    removeTimeObserver()
    playbackAudioSession.deactivate()
  }

  var activeStep: ProcedureStepResponse? {
    steps.first { $0.stepNumber == activeStepNumber }
  }

  var activeStepSummary: (title: String, subtitle: String?, icon: String, iconColor: Color) {
    if let step = activeStep {
      return (
        title: "Step \(step.stepNumber): \(step.title)",
        subtitle: step.formattedTimeRange,
        icon: "play.circle.fill",
        iconColor: .appPrimary
      )
    }

    if sourceVideoURL != nil {
      return (
        title: "Watch the full workflow or tap a step to jump in.",
        subtitle: nil,
        icon: "film",
        iconColor: .textSecondary
      )
    }

    return (
      title: "Review step details below while the source video is unavailable.",
      subtitle: nil,
      icon: "video.slash",
      iconColor: .textSecondary
    )
  }

  func configure(procedure: ProcedureResponse, serverBaseURL: String) {
    steps = procedure.steps.sorted { $0.timestampStart < $1.timestampStart }

    let resolvedURL = procedure.sourceVideoURL(serverBaseURL: serverBaseURL)
    let needsNewPlayer = resolvedURL != sourceVideoURL
    sourceVideoURL = resolvedURL

    if resolvedURL != nil {
      playbackAudioSession.activate()
    } else {
      playbackAudioSession.deactivate()
    }

    if needsNewPlayer {
      rebuildPlayer(with: resolvedURL)
    } else {
      refreshActiveStep(for: player?.currentTime().seconds ?? 0)
    }
  }

  func playStep(_ step: ProcedureStepResponse) {
    guard player != nil else { return }
    seek(to: step.timestampStart, autoplay: true)
  }

  func pause() {
    player?.pause()
  }

  func endPlaybackSession() {
    playbackAudioSession.deactivate()
  }

  func seek(to seconds: Double, autoplay: Bool) {
    guard let player else { return }
    let target = CMTime(seconds: seconds, preferredTimescale: 600)
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    refreshActiveStep(for: seconds)
    if autoplay {
      player.play()
    }
  }

  private func rebuildPlayer(with url: URL?) {
    removeTimeObserver()
    player?.pause()
    player = nil

    guard let url else {
      activeStepNumber = nil
      return
    }

    let player = AVPlayer(url: url)
    player.actionAtItemEnd = .pause
    self.player = player
    addTimeObserver(to: player)
    refreshActiveStep(for: 0)
  }

  private func addTimeObserver(to player: AVPlayer) {
    let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
    timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
      self?.refreshActiveStep(for: time.seconds)
    }
  }

  private func removeTimeObserver() {
    if let timeObserverToken, let player {
      player.removeTimeObserver(timeObserverToken)
    }
    timeObserverToken = nil
  }

  private func refreshActiveStep(for time: Double) {
    guard time.isFinite else {
      activeStepNumber = nil
      return
    }
    activeStepNumber = Self.activeStep(at: time, steps: steps)?.stepNumber
  }

  static func activeStep(at time: Double, steps: [ProcedureStepResponse]) -> ProcedureStepResponse? {
    guard time >= 0 else { return nil }

    let sortedSteps = steps.sorted { $0.timestampStart < $1.timestampStart }
    var currentStep: ProcedureStepResponse?

    for step in sortedSteps {
      if time >= step.timestampStart {
        currentStep = step
      } else {
        break
      }
    }

    return currentStep
  }
}

extension ProcedureResponse {
  func sourceVideoURL(serverBaseURL: String) -> URL? {
    let filename = sourceVideo ?? "\(id).mp4"
    return URL(string: "\(serverBaseURL)/api/uploads/\(filename)")
  }
}

enum ProcedureDisplayFormat {
  static func timestamp(_ seconds: Double) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
  }

  static func date(_ isoString: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: isoString) {
      let display = DateFormatter()
      display.dateStyle = .medium
      return display.string(from: date)
    }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: isoString) {
      let display = DateFormatter()
      display.dateStyle = .medium
      return display.string(from: date)
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
    let lastCharacterInSlice = slice.last
    let nextCharacter = description[limitIndex]
    var previewText = slice.trimmingCharacters(in: .whitespacesAndNewlines)

    let cutThroughWord = (lastCharacterInSlice?.isWhitespace == false) && !nextCharacter.isWhitespace
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
    ProcedureDisplayFormat.timestamp(timestampStart) + " \u{2013} " + ProcedureDisplayFormat.timestamp(timestampEnd)
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
