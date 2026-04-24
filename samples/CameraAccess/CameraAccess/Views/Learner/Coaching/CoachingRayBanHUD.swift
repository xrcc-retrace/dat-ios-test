import SwiftUI

struct CoachingRayBanHUD: View {
  @ObservedObject var viewModel: CoachingSessionViewModel
  let stepCount: Int
  let clipURL: URL?
  let showGestureDebug: Bool
  let onExit: () -> Void

  @StateObject private var hoverCoordinator = HUDHoverCoordinator()
  @State private var exitFlowState: ExitFlowState = .inactive
  @State private var stepCardPresentationState: StepCardPresentationState = .content
  @State private var stepCardTransitionID = UUID()
  @State private var isStepDetailExpanded: Bool = false
  @State private var pulseOpacity: CGFloat = 0

  private let holdTimer = Timer.publish(
    every: RayBanHUDLayoutTokens.exitHoldTimerInterval,
    on: .main,
    in: .common
  ).autoconnect()

  var body: some View {
    GeometryReader { geometry in
      let viewport = RayBanHUDViewport(size: geometry.size)

      ZStack {
        if shouldShowScrim {
          Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: handleScrimTap)
            .ignoresSafeArea()
        }

        squareContent
          .frame(width: viewport.squareSide, height: viewport.squareSide)
          .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: viewport.alignment
          )
          .padding(.trailing, viewport.trailingInset)
          .padding(.bottom, viewport.bottomInset)

        // Single shared gesture-debug stack — composes the landmark
        // overlay + event log with identical placement across Coaching,
        // Expert, and Troubleshoot HUDs. See HandGestureDebugStack.swift.
        // Hidden by default; re-enabled via the Debug toggle in the
        // coaching drawer's controls bar so demo footage stays clean.
        if showGestureDebug {
          HandGestureDebugStack(provider: viewModel)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .environmentObject(hoverCoordinator)
    .onChange(of: viewModel.hudStepTransitionState) { _, newState in
      guard case .idle = newState else { return }
      stepCardTransitionID = UUID()
      withAnimation(.easeOut(duration: RayBanHUDLayoutTokens.stepContentRevealDuration)) {
        stepCardPresentationState = .content
      }
    }
    .onChange(of: viewModel.stepJustCompletedTick) { _, _ in
      triggerCompletionPulse()
    }
    .onReceive(holdTimer) { _ in
      guard case .holding(let startedAt, _) = exitFlowState else { return }

      let elapsed = Date().timeIntervalSince(startedAt)
      let progress = min(1, CGFloat(elapsed / RayBanHUDLayoutTokens.exitHoldDuration))
      exitFlowState = .holding(startedAt: startedAt, progress: progress)

      if progress >= 1 {
        exitFlowState = .inactive
        hoverCoordinator.cancel()
        onExit()
      }
    }
  }

  @ViewBuilder
  private var squareContent: some View {
    if viewModel.isCompleted {
      completionContent
    } else if let progress = exitFlowState.progress {
      exitOverlay(progress: progress)
    } else {
      primaryContent
    }
  }

  private var primaryContent: some View {
    VStack(alignment: .trailing, spacing: 0) {
      Spacer(minLength: 0)
      bottomContentCluster
    }
  }

  private var bottomContentCluster: some View {
    VStack(alignment: .trailing, spacing: RayBanHUDLayoutTokens.exitToPanelSpacing) {
      activePanelStack

      exitPill
    }
  }

  private var activePanelStack: some View {
    VStack(alignment: .trailing, spacing: RayBanHUDLayoutTokens.stackSpacing) {
      if viewModel.showPiP || isStepDetailExpanded {
        detailPanel
      }

      stepCard
    }
  }

  private var exitPill: some View {
    RayBanHUDExitPill {
      hoverCoordinator.hovered == .exitWorkflow
    } onHoldStart: {
      if case .inactive = exitFlowState {
        exitFlowState = .holding(startedAt: Date(), progress: 0)
      }
    } onHoldEnd: {
      if case .holding(_, let progress) = exitFlowState, progress < 1 {
        cancelExitFlow()
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private var stepCard: some View {
    RayBanHUDStepCard(
      mode: stepCardMode,
      horizontalOffset: stepCardOffset,
      onConfirm: {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
          isStepDetailExpanded.toggle()
        }
      },
      onDragChanged: handleStepCardDragChanged,
      onDragEnded: handleStepCardDragEnded,
      isSwipeEnabled: canSwipeStepCard
    )
    .overlay(
      RoundedRectangle(cornerRadius: RayBanHUDLayoutTokens.cardRadius, style: .continuous)
        .fill(Color.green.opacity(pulseOpacity))
        .allowsHitTesting(false)
    )
  }

  private var detailPanel: some View {
    RayBanHUDDetailPanel(
      clipURL: clipURL,
      onConfirm: {
        viewModel.showPiP = false
      }
    )
  }

  private func exitOverlay(progress: CGFloat) -> some View {
    RayBanHUDExitOverlay(progress: progress) {
      cancelExitFlow()
    }
  }

  private var completionContent: some View {
    VStack(spacing: RayBanHUDLayoutTokens.stackSpacing) {
      Spacer(minLength: 0)

      RayBanHUDCompletionSummaryCard(onConfirm: onExit)

      RayBanHUDCompletionActionCard(
        icon: "sparkles.rectangle.stack.fill",
        label: "Saved Workflows",
        id: .completionSavedWorkflows,
        onConfirm: onExit
      )

      RayBanHUDCompletionActionCard(
        icon: "stethoscope",
        label: "Troubleshoot",
        id: .completionTroubleshoot,
        onConfirm: onExit
      )

      Spacer(minLength: 0)
    }
  }

  private var stepCardMode: RayBanHUDStepCardMode {
    switch stepCardPresentationState {
    case .content, .dragging:
      return .content(
        stepIndex: viewModel.currentStepIndex + 1,
        stepCount: stepCount,
        step: viewModel.currentStep,
        isExpanded: isStepDetailExpanded
      )
    case .loadingIncoming(_, let targetStepNumber):
      return .loading(stepIndex: targetStepNumber, stepCount: stepCount)
    }
  }

  private var stepCardOffset: CGFloat {
    if case .dragging(let offset, _) = stepCardPresentationState {
      return offset
    }
    return 0
  }

  private var canSwipeStepCard: Bool {
    hoverCoordinator.hovered == .stepCard
      && exitFlowState.progress == nil
      && !isStepDetailExpanded
      && viewModel.canPerformManualHUDNavigation
  }

  private var shouldShowScrim: Bool {
    hoverCoordinator.hovered != nil
      || exitFlowState.progress != nil
      || isStepDetailExpanded
  }

  private func handleScrimTap() {
    if exitFlowState.progress != nil {
      cancelExitFlow()
    } else if isStepDetailExpanded {
      hoverCoordinator.cancel()
      withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
        isStepDetailExpanded = false
      }
    } else if viewModel.hudStepTransitionState != .idle {
      return
    } else {
      hoverCoordinator.cancel()
      withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
        stepCardPresentationState = .content
      }
    }
  }

  private func triggerCompletionPulse() {
    let duration = RayBanHUDLayoutTokens.completionPulseDuration
    withAnimation(.easeInOut(duration: duration).repeatCount(2, autoreverses: true)) {
      pulseOpacity = 0.35
    }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(duration * 2 * 1_000_000_000))
      pulseOpacity = 0
      if isStepDetailExpanded {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
          isStepDetailExpanded = false
        }
      }
    }
  }

  private func cancelExitFlow() {
    exitFlowState = .inactive
    hoverCoordinator.cancel()
  }

  private func handleStepCardDragChanged(_ value: DragGesture.Value) {
    guard abs(value.translation.width) > abs(value.translation.height) else { return }

    let offset = value.translation.width
    let direction: StepNavigationDirection? =
      offset < 0 ? .next : (offset > 0 ? .previous : nil)

    stepCardPresentationState = .dragging(offset: offset, direction: direction)
  }

  private func handleStepCardDragEnded(_ value: DragGesture.Value) {
    guard abs(value.translation.width) > abs(value.translation.height) else {
      withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
        stepCardPresentationState = .content
      }
      return
    }

    let translation = value.translation.width
    let direction: StepNavigationDirection =
      translation < 0 ? .next : .previous

    if direction == .previous && viewModel.currentStepIndex == 0 {
      withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
        stepCardPresentationState = .content
      }
      return
    }

    let commitThreshold = RayBanHUDLayoutTokens.stepSwipeCommitThreshold
    let committed =
      (direction == .next && translation <= -commitThreshold)
      || (direction == .previous && translation >= commitThreshold)

    guard committed else {
      withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
        stepCardPresentationState = .content
      }
      return
    }

    // Re-check readiness at commit time — a tool call could have landed mid-drag.
    guard viewModel.canPerformManualHUDNavigation else {
      withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
        stepCardPresentationState = .content
      }
      return
    }

    commitStepCardSwipe(direction: direction)
  }

  private func commitStepCardSwipe(direction: StepNavigationDirection) {
    let transitionID = UUID()
    let targetStepNumber = predictedTargetStepNumber(for: direction)
    stepCardTransitionID = transitionID

    withAnimation(.easeIn(duration: RayBanHUDLayoutTokens.stepSwipeCommitDuration)) {
      stepCardPresentationState = .dragging(
        offset: offscreenOffset(for: direction),
        direction: direction
      )
    }

    Task { @MainActor in
      try? await Task.sleep(nanoseconds: RayBanHUDLayoutTokens.stepSwipeCommitDelayNanoseconds)
      guard stepCardTransitionID == transitionID else { return }
      guard viewModel.hudStepTransitionState != .idle else { return }

      withAnimation(.easeOut(duration: RayBanHUDLayoutTokens.stepLoadingTransitionDuration)) {
        stepCardPresentationState = .loadingIncoming(
          direction: direction,
          targetStepNumber: targetStepNumber
        )
      }
    }

    Task {
      await viewModel.navigateStepFromHUD(direction: direction)
    }
  }

  private func predictedTargetStepNumber(for direction: StepNavigationDirection) -> Int? {
    switch direction {
    case .next:
      let predicted = viewModel.currentStepIndex + 2
      return predicted <= stepCount ? predicted : nil
    case .previous:
      guard viewModel.currentStepIndex > 0 else { return nil }
      return viewModel.currentStepIndex
    }
  }

  private func offscreenOffset(for direction: StepNavigationDirection) -> CGFloat {
    switch direction {
    case .next:
      return -RayBanHUDLayoutTokens.stepSwipeOffscreenOffset
    case .previous:
      return RayBanHUDLayoutTokens.stepSwipeOffscreenOffset
    }
  }
}

private enum ExitFlowState: Equatable {
  case inactive
  case holding(startedAt: Date, progress: CGFloat)

  var progress: CGFloat? {
    if case .holding(_, let progress) = self {
      return progress
    }
    return nil
  }
}

private enum StepCardPresentationState: Equatable {
  case content
  case dragging(offset: CGFloat, direction: StepNavigationDirection?)
  case loadingIncoming(direction: StepNavigationDirection, targetStepNumber: Int?)
}

enum RayBanHUDLayoutTokens {
  static let viewportInset: CGFloat = 24
  static let contentPadding: CGFloat = 20
  static let stackSpacing: CGFloat = 12
  static let exitToPanelSpacing: CGFloat = 8
  static let cardRadius: CGFloat = 24
  static let iconFrame: CGFloat = 36
  static let completionHeight: CGFloat = 140
  static let completionActionRadius: CGFloat = 22
  static let detailHeight: CGFloat = 180
  static let stepCardMinHeight: CGFloat = 124
  /// Fixed content height for the step card's scrollable body (STEP label +
  /// title + description). Tweak to taste — at 100 the description is one
  /// short line before scrolling kicks in, useful when the HUD is squeezed
  /// into the lower-right landscape viewport.
  static let stepCardContentHeight: CGFloat = 100
  static let stepSwipeMinimumDistance: CGFloat = 12
  static let stepSwipeCommitThreshold: CGFloat = 80
  static let stepSwipeOffscreenOffset: CGFloat = 420
  static let stepSwipeCommitDuration: Double = 0.18
  static let stepLoadingTransitionDuration: Double = 0.14
  static let stepContentRevealDuration: Double = 0.18
  static let stepSwipeCommitDelayNanoseconds: UInt64 = 180_000_000
  static let exitHoldDuration: TimeInterval = 2.0
  static let exitHoldTimerInterval: TimeInterval = 1.0 / 30.0
  /// Single knob for the compact step-card "Read more" truncation cutoff.
  /// Tweak here to shrink or grow before the inline italic "Read more" kicks in.
  static let stepDescriptionCharacterLimit: Int = 75
  /// Single half-cycle of the green completion pulse. Full pulse = 2× this (autoreverse).
  static let completionPulseDuration: Double = 0.70
  /// Maximum width of the Exit workflow pill. Tweak here to widen or narrow
  /// the pill — it caps at this value and hugs the step card width below it.
  static let exitPillMaxWidth: CGFloat = 340
}

private struct RayBanHUDViewport {
  let squareSide: CGFloat
  let alignment: Alignment
  let trailingInset: CGFloat
  let bottomInset: CGFloat

  init(size: CGSize) {
    let isLandscape = size.width > size.height
    let shortEdge = min(size.width, size.height)

    squareSide = max(0, shortEdge - (RayBanHUDLayoutTokens.viewportInset * 2))
    alignment = isLandscape ? .bottomTrailing : .center
    trailingInset = isLandscape ? RayBanHUDLayoutTokens.viewportInset : 0
    bottomInset = isLandscape ? RayBanHUDLayoutTokens.viewportInset : 0
  }
}
