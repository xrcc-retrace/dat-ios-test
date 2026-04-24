import SwiftUI

/// Ray-Ban-style HUD overlay for the Expert recording screen. Mirrors
/// `CoachingRayBanHUD` in structure — GeometryReader → square viewport with
/// a bottom-cluster of panels — but is sized and populated for the expert's
/// needs during narration capture.
///
/// Contents, top-to-bottom within the square:
///   [top-center]     recording status chip   (only while recording)
///   [top-trailing]   mic-source badge        (always visible)
///   [bottom cluster]
///     ├─ stop-recording pill       (only while recording; hover-to-confirm)
///     ├─ rolling transcript card   (only while recording + available)
///     └─ narration tip card        (always visible; swipe to cycle)
///
/// When the user holds the stop pill, the entire cluster is replaced by
/// `ExpertHUDStopOverlay` — exactly the same treatment `CoachingRayBanHUD`
/// gives its exit overlay.
struct ExpertRayBanHUD: View {
  @ObservedObject var recordingManager: ExpertRecordingManager
  @ObservedObject var hud: ExpertRecordingHUDViewModel
  let showGestureDebug: Bool
  let onStop: () -> Void

  @StateObject private var hoverCoordinator = HUDHoverCoordinator()
  @State private var stopFlowState: StopFlowState = .inactive
  @State private var tipCardOffset: CGFloat = 0

  private let holdTimer = Timer.publish(
    every: RayBanHUDLayoutTokens.exitHoldTimerInterval,
    on: .main,
    in: .common
  ).autoconnect()

  var body: some View {
    GeometryReader { geometry in
      let viewport = ExpertRayBanHUDViewport(size: geometry.size)

      ZStack {
        if shouldShowScrim {
          Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: handleScrimTap)
            .ignoresSafeArea()
        }

        // Top floating elements — free-positioned outside the square cluster
        // so they don't compete with the bottom panels for space.
        topOverlay(in: geometry)

        // Bottom square cluster — matches the Learner HUD's positioning rules
        // (centered in portrait, bottom-trailing in landscape).
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
        // Hidden by default; re-enabled via the Gesture debug toggle in
        // the pre-recording chrome so demo footage stays clean.
        if showGestureDebug {
          HandGestureDebugStack(provider: hud)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .environmentObject(hoverCoordinator)
    .onReceive(holdTimer) { _ in
      guard case .holding(let startedAt, _) = stopFlowState else { return }
      let elapsed = Date().timeIntervalSince(startedAt)
      let progress = min(1, CGFloat(elapsed / RayBanHUDLayoutTokens.exitHoldDuration))
      stopFlowState = .holding(startedAt: startedAt, progress: progress)
      if progress >= 1 {
        stopFlowState = .inactive
        hoverCoordinator.cancel()
        onStop()
      }
    }
  }

  // MARK: - Top overlay

  @ViewBuilder
  private func topOverlay(in geometry: GeometryProxy) -> some View {
    VStack(spacing: RayBanHUDLayoutTokens.stackSpacing) {
      if recordingManager.isRecording {
        ExpertHUDRecordingStatusChip(
          duration: recordingManager.recordingDuration,
          audioPeak: hud.smoothedAudioPeak,
          isRecording: true
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .padding(.top, RayBanHUDLayoutTokens.viewportInset + 36)

    // Mic-source badge pinned top-trailing. We rely on RetraceScreen's
    // containing ZStack for absolute positioning; the badge gets its own
    // frame so the top-center recording chip isn't affected.
    HStack {
      Spacer(minLength: 0)
      ExpertHUDMicSourceBadge(micSource: hud.micSource)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    .padding(.top, RayBanHUDLayoutTokens.viewportInset + 36)
    .padding(.trailing, RayBanHUDLayoutTokens.viewportInset)
    .allowsHitTesting(false)
  }

  // MARK: - Square content

  @ViewBuilder
  private var squareContent: some View {
    if let progress = stopFlowState.progress {
      ExpertHUDStopOverlay(progress: progress) {
        cancelStopFlow()
      }
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
      if recordingManager.isRecording {
        HStack {
          Spacer(minLength: 0)
          stopPill
        }
      }

      VStack(alignment: .trailing, spacing: RayBanHUDLayoutTokens.stackSpacing) {
        if recordingManager.isRecording, hud.transcriptAvailable {
          ExpertHUDRollingTranscriptCard(segments: hud.transcript)
        }

        tipCard
      }
    }
  }

  private var stopPill: some View {
    ExpertHUDStopPill {
      hoverCoordinator.hovered == .expertStopRecording
    } onHoldStart: {
      if case .inactive = stopFlowState {
        stopFlowState = .holding(startedAt: Date(), progress: 0)
      }
    } onHoldEnd: {
      if case .holding(_, let progress) = stopFlowState, progress < 1 {
        cancelStopFlow()
      }
    }
  }

  private var tipCard: some View {
    ExpertHUDNarrationTipCard(
      tip: hud.currentTip,
      horizontalOffset: tipCardOffset,
      onDragChanged: handleTipDragChanged,
      onDragEnded: handleTipDragEnded
    )
  }

  // MARK: - Scrim + stop flow

  private var shouldShowScrim: Bool {
    hoverCoordinator.hovered != nil || stopFlowState.progress != nil
  }

  private func handleScrimTap() {
    if stopFlowState.progress != nil {
      cancelStopFlow()
    } else {
      hoverCoordinator.cancel()
    }
  }

  private func cancelStopFlow() {
    stopFlowState = .inactive
    hoverCoordinator.cancel()
  }

  // MARK: - Tip card swipe

  private func handleTipDragChanged(_ value: DragGesture.Value) {
    guard abs(value.translation.width) > abs(value.translation.height) else { return }
    tipCardOffset = value.translation.width
  }

  private func handleTipDragEnded(_ value: DragGesture.Value) {
    defer {
      withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
        tipCardOffset = 0
      }
    }
    guard abs(value.translation.width) > abs(value.translation.height) else { return }
    let threshold = RayBanHUDLayoutTokens.stepSwipeCommitThreshold
    let translation = value.translation.width
    if translation <= -threshold {
      hud.advanceTip()
    } else if translation >= threshold {
      hud.retreatTip()
    }
  }
}

// MARK: - Viewport

/// Expert-scoped viewport tokens. Mirrors `RayBanHUDViewport` from the
/// learner HUD — a square-side equal to the short edge minus the standard
/// viewport inset, centered in portrait and bottom-trailing in landscape.
private struct ExpertRayBanHUDViewport {
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

// MARK: - Flow state

private enum StopFlowState: Equatable {
  case inactive
  case holding(startedAt: Date, progress: CGFloat)

  var progress: CGFloat? {
    if case .holding(_, let progress) = self {
      return progress
    }
    return nil
  }
}
