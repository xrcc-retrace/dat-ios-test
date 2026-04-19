import SwiftUI

struct CoachingRayBanHUD: View {
  @ObservedObject var viewModel: CoachingSessionViewModel
  let stepCount: Int
  let clipURL: URL?
  let onExit: () -> Void

  @StateObject private var hoverCoordinator = HUDHoverCoordinator()
  @State private var exitFlowState: ExitFlowState = .inactive

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
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .environmentObject(hoverCoordinator)
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
    VStack(alignment: .trailing, spacing: RayBanHUDLayoutTokens.stackSpacing) {
      HStack {
        Spacer(minLength: 0)
        exitPill
      }

      Spacer(minLength: 0)

      if viewModel.showPiP {
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
  }

  private var stepCard: some View {
    RayBanHUDStepCard(
      stepIndex: viewModel.currentStepIndex + 1,
      stepCount: stepCount,
      step: viewModel.currentStep,
      onConfirm: {
        viewModel.showPiP = true
      }
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

      RayBanHUDCompletionActionPill(
        icon: "sparkles.rectangle.stack.fill",
        label: "Saved Workflows",
        id: .completionSavedWorkflows,
        onConfirm: onExit
      )

      RayBanHUDCompletionActionPill(
        icon: "stethoscope",
        label: "Troubleshoot",
        id: .completionTroubleshoot,
        onConfirm: onExit
      )

      Spacer(minLength: 0)
    }
  }

  private var shouldShowScrim: Bool {
    hoverCoordinator.hovered != nil || exitFlowState.progress != nil
  }

  private func handleScrimTap() {
    if exitFlowState.progress != nil {
      cancelExitFlow()
    } else {
      hoverCoordinator.cancel()
    }
  }

  private func cancelExitFlow() {
    exitFlowState = .inactive
    hoverCoordinator.cancel()
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

enum RayBanHUDLayoutTokens {
  static let viewportInset: CGFloat = 24
  static let contentPadding: CGFloat = 24
  static let stackSpacing: CGFloat = 16
  static let cardRadius: CGFloat = 28
  static let iconFrame: CGFloat = 40
  static let completionHeight: CGFloat = 165
  static let detailHeight: CGFloat = 208
  static let exitHoldDuration: TimeInterval = 2.0
  static let exitHoldTimerInterval: TimeInterval = 1.0 / 30.0
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
