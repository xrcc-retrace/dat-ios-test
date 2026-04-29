import SwiftUI

/// The single Coaching lens page during an active step. Hosts the step
/// card and two top-row toggle affordances ("Reference" top-left,
/// "Insights" top-right).
///
/// Layout modes:
///   • `.collapsed` — full step card visible; affordances small at the top
///   • `.referenceExpanded` — clip player takes the main focus area; step
///     card shrinks to a compact header
///   • `.insightsExpanded` — insights tabs + content take the main focus
///     area; step card shrinks to a compact header
///
/// Affordance buttons hide automatically when their content isn't
/// available for the current step (no clip → no Reference button; no
/// tips/warnings/red-flags → no Insights button). On step transition the
/// expansion resets to `.collapsed` so the user starts each step from the
/// default view.
///
/// Exit happens either via the bottom-right Exit capsule or via
/// `RayBanHUDEmulator`'s `onLensBackGesture` callback wired from
/// `CoachingSessionView`. Both paths open the same confirmation overlay.
/// Step transitions remain driven by Gemini Live tool calls
/// (`advance_step`).
struct CoachingStepPage: RayBanHUDView {
  @ObservedObject var viewModel: CoachingSessionViewModel
  let stepCount: Int
  let clipURL: URL?
  /// Callback the focus engine's step-page handler invokes when the user
  /// dispatches `.dismiss` (lens double-tap, future MediaPipe back).
  /// Parent (`CoachingSessionView`) flips its `showDismissConfirmation`
  /// flag, which renders the exit confirmation overlay.
  let onShowExitConfirmation: () -> Void
  /// True while a confirmation overlay is rendered on top of the page
  /// (and the page is receded via `.rayBanHUDRecede`). Suspends the
  /// step card's auto-scroll so the user returns to the same scroll
  /// position when the overlay dismisses, instead of finding the text
  /// having drifted underneath the blur.
  let isOverlayActive: Bool

  @EnvironmentObject private var hoverCoordinator: HUDHoverCoordinator
  @State private var expansion: ExpansionState = .collapsed
  /// User's explicit pause toggle for the auto-scrolling description.
  /// Pinch-select on `.stepCard` flips this when the description is
  /// overflowing; otherwise pinch-select toggles `expansion` (existing
  /// behavior). Reset on step change and when leaving `.stepExpanded`.
  @State private var autoScrollIsUserPaused: Bool = false
  /// Reported up by `AutoScrollingContainer` inside the step card. True
  /// when the rendered description content is taller than the card's
  /// viewport. Drives the pinch-select branch.
  @State private var autoScrollIsOverflowing: Bool = false

  init(
    viewModel: CoachingSessionViewModel,
    stepCount: Int,
    clipURL: URL?,
    isOverlayActive: Bool = false,
    onShowExitConfirmation: @escaping () -> Void
  ) {
    self.viewModel = viewModel
    self.stepCount = stepCount
    self.clipURL = clipURL
    self.isOverlayActive = isOverlayActive
    self.onShowExitConfirmation = onShowExitConfirmation
  }

  enum ExpansionState: Equatable {
    case collapsed
    case referenceExpanded
    case insightsExpanded
    /// Tapping the step card swaps `RayBanHUDStepCard`'s `isExpanded`
    /// flag from `false` → `true`: full description + inline insights
    /// instead of a truncated preview. Mutually exclusive with
    /// reference / insights expansions, so this state cleanly hides
    /// either of those panels if one was already open.
    case stepExpanded
  }

  var body: some View {
    primaryContent
      .onChange(of: viewModel.currentStepIndex) { _, _ in
        // New step → reset to the default view so the user isn't stranded
        // on stale reference/insights content from the previous step.
        // Also reset the cursor to `.stepCard` since the previously
        // focused control (e.g. `.referenceClip`) may no longer exist
        // in the post-collapse graph — leaving the cursor on a missing
        // node would silently swallow directional input.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
          expansion = .collapsed
          hoverCoordinator.hovered = .stepCard
        }
        // Auto-scroll resets via the `resetKey` inside
        // `AutoScrollingContainer`, but the user's explicit pause
        // toggle is page state — clear it so a fresh step starts
        // running.
        autoScrollIsUserPaused = false
      }
      .onChange(of: expansion) { _, newValue in
        // Leaving `.stepExpanded` (collapse, or jump to reference /
        // insights) → no auto-scroll any more, so the explicit pause
        // toggle should reset. Re-entering `.stepExpanded` next time
        // starts running.
        if newValue != .stepExpanded {
          autoScrollIsUserPaused = false
        }
      }
      // Focus-engine handler. Pushed onto the coordinator's stack on
      // appear, popped on disappear. Default focus = .stepCard. Up/down
      // on the step card traverses the focus graph (Reference / Insights
      // toggles, the reference clip when expanded, the bottom audio row).
      // Left/right on the step card are commit-on-release — see the
      // HandGestureService listener below for terminal pinch step nav.
      .hudInputHandler { coord in
        CoachingStepPageHandler(
          coordinator: coord,
          onAdvanceStep: {
            Task { await viewModel.navigateStepFromHUD(direction: .next) }
          },
          onRetreatStep: {
            Task { await viewModel.navigateStepFromHUD(direction: .previous) }
          },
          hasReference: { clipURL != nil },
          hasInsights: {
            guard let step = viewModel.currentStep else { return false }
            return !step.populatedInsightCategories.isEmpty
          },
          isReferenceExpanded: { expansion == .referenceExpanded },
          onSetMuted: { muted in
            viewModel.setMuted(muted)
          },
          onShowExitConfirmation: onShowExitConfirmation
        )
      }
      // Pinch-drag-release → step nav, but only when the cursor is on
      // the step card. Highlights are intentionally ignored (the page
      // handler returns false for `.directional(.left/.right)` on
      // `.stepCard`); only terminal release events fire here. Mirrors
      // `ExpertNarrationTipPage`'s carousel — same release-to-commit
      // intent, same single-slot listener on `HandGestureService.shared`.
      // Gating on `coordinator.hovered == .stepCard` keeps the listener
      // silent when an exit overlay or expanded reference / insights
      // panel has moved focus elsewhere — page-global step skips during
      // those moments would surprise the learner.
      .onAppear {
        let coord = hoverCoordinator
        HandGestureService.shared.onEvent = { event in
          Task { @MainActor in
            guard coord.hovered == .stepCard else { return }
            switch event {
            case .right:
              await viewModel.navigateStepFromHUD(direction: .next)
            case .left:
              await viewModel.navigateStepFromHUD(direction: .previous)
            default:
              break
            }
          }
        }
      }
      .onDisappear {
        HandGestureService.shared.onEvent = nil
      }
  }

  // MARK: - Primary content

  private var primaryContent: some View {
    VStack(spacing: 8) {
      topAffordances

      contentArea

      bottomActionRow
    }
    .padding(RayBanHUDLayoutTokens.contentPadding)
    // Note: the spring animating the `.id(displayedStepIndex)` slide
    // transition is opened by the VM via `withAnimation(.spring(...))`
    // around the `displayedStepIndex` mutation — NOT a `.animation(...,
    // value:)` modifier here. A scoped `.animation` modifier was tried
    // first but produced a one-frame layout flicker on the host card
    // when other VM state (e.g. `slideDirection`) changed in the same
    // render, even with `value:` unchanged.
  }

  // MARK: - Top-row toggle affordances

  private var hasClip: Bool { clipURL != nil }
  private var hasInsights: Bool {
    guard let step = viewModel.currentStep else { return false }
    return !step.populatedInsightCategories.isEmpty
  }

  @ViewBuilder
  private var topAffordances: some View {
    HStack(alignment: .center, spacing: 8) {
      // Reference pill is always visible. The trailing status dot signals
      // at a glance whether this step has a reference image/video (green)
      // or is instructional only (gray) — so the user doesn't have to tap
      // to find out.
      toggleAffordance(
        label: expansion == .referenceExpanded ? "Hide ref" : "Reference",
        icon: "play.rectangle",
        id: .toggleReference,
        isActive: expansion == .referenceExpanded,
        statusDot: hasClip ? .referenceActive : .empty
      ) {
        toggleExpansion(.referenceExpanded)
      }

      Spacer(minLength: 0)

      // Insights pill — same always-visible pattern. Yellow dot when the
      // step has any tips/warnings/error_criteria; gray when not.
      toggleAffordance(
        label: expansion == .insightsExpanded ? "Hide insights" : "Insights",
        icon: "lightbulb",
        id: .toggleInsights,
        isActive: expansion == .insightsExpanded,
        statusDot: hasInsights ? .insightsActive : .empty
      ) {
        toggleExpansion(.insightsExpanded)
      }
    }
    .frame(height: 32)
  }

  /// Bottom-of-lens action row. Mute and Exit are the two selectable
  /// surfaces; the wide waveform between them is passive status only so
  /// it cannot be mistaken for a mic control.
  private var bottomActionRow: some View {
    RayBanHUDBottomAudioActionRow(
      isMuted: viewModel.isMuted,
      aiPeak: viewModel.aiOutputPeak,
      userPeak: viewModel.userInputPeak,
      muteControl: .toggleMute,
      exitControl: .exitWorkflowButton,
      onToggleMute: { viewModel.toggleMute() },
      onExit: onShowExitConfirmation
    )
  }

  /// Color-coded availability dot drawn in the trailing edge of a toggle
  /// pill. Same dot shape across both pills; only the "active" color
  /// differs so the pattern reads as one design language.
  enum StatusDotState {
    case referenceActive  // green — clip is available
    case insightsActive   // yellow — at least one of tips/warnings/error_criteria
    case empty            // neutral gray — no content for this step
  }

  private func toggleAffordance(
    label: String,
    icon: String,
    id: HUDControl,
    isActive: Bool,
    statusDot: StatusDotState? = nil,
    onTap: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold))
      Text(label)
        .font(.inter(.medium, size: 13))
        .lineLimit(1)
      if let statusDot {
        Circle()
          .fill(color(for: statusDot, isActive: isActive))
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)
      }
    }
    .foregroundStyle(
      isActive ? Color.black.opacity(0.88) : Color.white.opacity(0.94)
    )
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(
      Capsule()
        .fill(isActive ? Color.white.opacity(0.95) : Color.clear)
    )
    .rayBanHUDPanel(shape: .capsule)
    .hoverSelectable(id, shape: .capsule, onConfirm: onTap)
  }

  /// Resolve the dot fill color. When the pill is `isActive` (white fill),
  /// boost the dot's contrast so it stays visible on the bright surface.
  private func color(for dot: StatusDotState, isActive: Bool) -> Color {
    switch dot {
    case .referenceActive:
      // Use the project's green token; on the white-active pill, swap to
      // a deeper green so it doesn't wash out.
      return isActive ? Color.semanticSuccess.opacity(0.95) : Color.semanticSuccess
    case .insightsActive:
      // No "warm yellow" token in the palette; keep a soft amber that
      // matches the lightbulb's natural connotation. Slightly darker
      // when sitting on the active white capsule so it stays readable.
      let warm = Color(red: 1.00, green: 0.78, blue: 0.20)
      return isActive ? warm.opacity(0.95) : warm
    case .empty:
      // Desaturated neutral. On the dark inactive capsule we want it
      // muted but readable; on the white active capsule we want darker
      // so it stays visible.
      return isActive ? Color.black.opacity(0.30) : Color.white.opacity(0.30)
    }
  }

  private func toggleExpansion(_ target: ExpansionState) {
    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
      expansion = (expansion == target) ? .collapsed : target
    }
  }

  // MARK: - Content area

  @ViewBuilder
  private var contentArea: some View {
    VStack(spacing: 10) {
      if expansion == .referenceExpanded {
        clipPanel
          .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)),
            removal: .opacity
          ))
      }

      if expansion == .insightsExpanded {
        insightsPanel
          .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)),
            removal: .opacity
          ))
      }

      stepCard
    }
    .frame(maxHeight: expansion == .stepExpanded ? .infinity : nil)
  }

  // MARK: - Step card

  private var stepCard: some View {
    Group {
      switch expansion {
      case .collapsed, .stepExpanded:
        // Same component for both — `RayBanHUDStepCard` reads
        // `isExpanded` from `stepCardMode` and grows the description
        // accordingly. The `withAnimation(.spring(...))` in
        // `toggleExpansion` smoothly animates the size change.
        // Auto-scroll bindings flow through to the inner
        // `AutoScrollingContainer` when the card is expanded.
        RayBanHUDStepCard(
          mode: stepCardMode,
          autoScrollIsUserPaused: $autoScrollIsUserPaused,
          autoScrollIsOverflowing: $autoScrollIsOverflowing,
          autoScrollIsExternallySuspended: isOverlayActive
        )
          // Expanded mode: claim the remaining lens height so the card's
          // inner `ScrollView` has space to scroll. Collapsed mode keeps
          // its natural intrinsic height so layout doesn't shift.
          .frame(
            maxHeight: expansion == .stepExpanded ? .infinity : nil,
            alignment: .top
          )
      case .referenceExpanded, .insightsExpanded:
        compactStepHeader
      }
    }
    // Step-completion celebration overlay. `celebratingStepIndex` is set
    // to the OLD step index for the full ~1.0s window (0.7s overlay
    // playback + 0.3s slide), so this card is the one that "wears" the
    // green + checkmark; the incoming card matches a different index
    // and stays clean.
    .overlay(
      StepCompletionOverlay(
        isCelebrating: viewModel.celebratingStepIndex == viewModel.displayedStepIndex
      )
    )
    // Modifier order is deliberate: `.transition` MUST come before
    // `.id`. SwiftUI applies modifiers bottom-up, so the transition
    // here is on the inner view and is read at the moment `.id`
    // invalidates that view's identity, producing a clean
    // insertion/removal animation. Inverting the order causes the
    // transition value to be re-evaluated on every render where any
    // VM state changes (e.g. `slideDirection` flipping at t=0), which
    // produces a brief layout twitch on the host card.
    .transition(stepSlideTransition)
    .id(viewModel.displayedStepIndex)
    // Pinch-select / tap on the step card has overloaded semantics
    // driven by current state:
    //
    // - Card is **already expanded** (`.stepExpanded`): the input
    //   stays in expanded mode. Pause / resume the auto-scroll if the
    //   description is overflowing; otherwise no-op (the user
    //   re-expanding what's already expanded would shrink it back —
    //   unwanted, since they're trying to read). Collapse only happens
    //   indirectly: open Reference / Insights, advance step, or use
    //   the lens dismiss gesture.
    // - Card is **collapsed** (or focused on a different expansion
    //   like Reference / Insights): toggle into `.stepExpanded`.
    //   Mutually exclusive with reference / insights expansion via
    //   `toggleExpansion`.
    .hoverSelectable(.stepCard, shape: .rounded(RayBanHUDLayoutTokens.cardRadius)) {
      if expansion == .stepExpanded {
        if autoScrollIsOverflowing {
          autoScrollIsUserPaused.toggle()
        }
        // No-op when content fits — collapsing what the user just
        // expanded to read would surprise them.
      } else {
        toggleExpansion(.stepExpanded)
      }
    }
  }

  private var stepCardMode: RayBanHUDStepCardMode {
    // The HUD shows `displayedStep`, not `currentStep`. They're equal in
    // steady state; during a forward `advance_step` celebration the
    // displayed step lags the canonical one by ~0.7s so the OLD card
    // stays visible long enough for the green-overlay + checkmark
    // sequence to play before sliding off.
    //
    // No "loading" mode any more: the celebration overlay (green +
    // checkmark) is the affirmative feedback for an advance, and a
    // manual-nav in-flight tool call no longer paints a ProgressView
    // over the card. (`hudStepTransitionState` is still tracked on the
    // VM so `canPerformManualHUDNavigation` can gate against
    // double-firing — only the visual loading mode is gone.)
    return .content(
      stepIndex: viewModel.displayedStepIndex + 1,
      stepCount: stepCount,
      step: viewModel.displayedStep,
      isExpanded: expansion == .stepExpanded
    )
  }

  /// Asymmetric slide transition for the step card. Forward = old slides
  /// off-left while new arrives from the right; backward inverts both
  /// edges. `.none` (steady state, initial mount, intra-step expansion
  /// toggles) returns `.identity` so we don't animate the card sliding
  /// in on first appearance.
  private var stepSlideTransition: AnyTransition {
    switch viewModel.slideDirection {
    case .none:
      return .identity
    case .forward:
      return .asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
      )
    case .backward:
      return .asymmetric(
        insertion: .move(edge: .leading).combined(with: .opacity),
        removal: .move(edge: .trailing).combined(with: .opacity)
      )
    }
  }

  private var compactStepHeader: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        // Mirror the full step card — use the lagged `displayedStep`
        // so the lens content stays consistent during the celebration
        // window. (In practice the onChange handler at the top of body
        // collapses Reference/Insights to .collapsed before the slide
        // starts, so this branch usually isn't even rendered during a
        // step transition; using `displayedStep` here is just defensive
        // consistency.)
        Text("STEP \(viewModel.displayedStepIndex + 1) OF \(stepCount)")
          .font(.inter(.medium, size: 10))
          .tracking(1.0)
          .foregroundStyle(Color.white.opacity(0.7))
        if let step = viewModel.displayedStep {
          Text(step.title)
            .font(.inter(.bold, size: 14))
            .foregroundStyle(Color.white.opacity(0.96))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
  }

  // MARK: - Reference + insights expanded panels

  private var clipPanel: some View {
    RayBanHUDDetailPanel(clipURL: clipURL)
  }

  private var insightsPanel: some View {
    InsightsExpandedPanel(step: viewModel.currentStep)
  }

}

// MARK: - Inline insights panel

/// Inline insights view used inside `CoachingStepPage`'s expanded mode.
/// Same content the old standalone `CoachingInsightsPage` rendered, but
/// scoped to a panel that sits above a compacted step header.
private struct InsightsExpandedPanel: View {
  let step: ProcedureStepResponse?

  @State private var selected: InsightCategory?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header

      if let step, !step.populatedInsightCategories.isEmpty {
        insightsContent(for: step)
      } else {
        emptyStatePlaceholder
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(RayBanHUDLayoutTokens.contentPadding)
    .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
    .onChange(of: step?.id) { _, _ in selected = nil }
  }

  /// Mirrors the reference panel's "No reference" empty state so both
  /// surfaces feel like the same design language when a step lacks
  /// content. Centered, icon + title + supporting subtitle, no CTA.
  private var emptyStatePlaceholder: some View {
    VStack(spacing: 10) {
      Image(systemName: "lightbulb.slash")
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.78))

      Text("No insights")
        .font(.inter(.bold, size: 16))
        .foregroundStyle(Color.white.opacity(0.82))

      Text("Just follow the step instructions.")
        .font(.inter(.medium, size: 12))
        .foregroundStyle(Color.white.opacity(0.62))
    }
    .frame(maxWidth: .infinity)
    .multilineTextAlignment(.center)
    .padding(.vertical, 6)
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: "lightbulb.fill")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.11))
      Text("INSIGHTS")
        .font(.inter(.bold, size: 11))
        .tracking(1.2)
        .foregroundStyle(Color.white.opacity(0.85))
    }
  }

  @ViewBuilder
  private func insightsContent(for step: ProcedureStepResponse) -> some View {
    let categories = step.populatedInsightCategories
    let active = selected ?? categories.first

    if categories.count >= 2 {
      tabs(categories: categories, active: active)
    } else if let single = categories.first {
      Text(single.displayName)
        .font(.inter(.bold, size: 13))
        .foregroundStyle(Color.white.opacity(0.94))
    }

    if let active {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(active.items(for: step).enumerated()), id: \.offset) { _, item in
          HStack(alignment: .top, spacing: 6) {
            Text("•")
              .font(.inter(.medium, size: 13))
              .foregroundStyle(Color.white.opacity(0.9))
            Text(item)
              .font(.inter(.medium, size: 13))
              .foregroundStyle(Color.white.opacity(0.96))
              .lineSpacing(2)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func tabs(categories: [InsightCategory], active: InsightCategory?) -> some View {
    HStack(spacing: 6) {
      ForEach(categories, id: \.self) { category in
        let isActive = category == active
        Text(category.displayName)
          .font(.inter(.medium, size: 12))
          .foregroundStyle(isActive ? Color.black.opacity(0.9) : Color.white.opacity(0.92))
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(
            Capsule().fill(isActive ? Color.white.opacity(0.95) : Color.white.opacity(0.08))
          )
          .hoverSelectable(.insightsTab(category), shape: .capsule) {
            selected = category
          }
      }
      Spacer(minLength: 0)
    }
  }
}
