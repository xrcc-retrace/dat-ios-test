import SwiftUI

/// Self-contained square Ray-Ban lens host. Renders an ordered stack of
/// pages (any `RayBanHUDView` conformer) inside a centered square viewport
/// and paginates between them with a single horizontal swipe gesture.
///
/// What the emulator owns (so pages don't have to):
///   • Square viewport sizing — `min(width, height) − inset` per `GeometryReader`.
///     Pages are designed *for* a square; the emulator clips/centers them.
///   • Hard clip to the square (`.clipped`). Swipe-out animations disappear
///     at the lens edge — mirroring the real Ray-Ban Display. No hard-coded
///     "off-screen" magic numbers; slide distance derives from `viewportSide`.
///   • Shared `HUDHoverCoordinator` injected via `.environmentObject` — every
///     `.hoverSelectable(...)` modifier in any page resolves against the same
///     coordinator instance.
///   • Scrim (full-bleed `Color.clear` with tap-to-cancel-hover) when any
///     page element is hovered.
///   • Page-indicator dot strip at the bottom of the lens (hidden when
///     `pageCount <= 1`).
///   • The single gesture pipeline. Finger drag here today, MediaPipe
///     `PinchDragRecognizer` tomorrow — both mutate the same `pageIndex`
///     binding. Pages never wire gesture code; adding a page anywhere
///     auto-inherits navigation.
struct RayBanHUDEmulator<PageContent: View>: View {
  let pageCount: Int
  @Binding var pageIndex: Int
  /// When true, draws a visible outline + dimensions label around the lens
  /// square so you can see exactly what space pages render into. Wire this
  /// to a debug toggle at the call site (e.g. the controls-bar Debug button
  /// in `CoachingSessionView`) — useful while iterating on page placement.
  let showBoundary: Bool
  /// When true, the entire lens content composes into one offscreen layer
  /// and renders with `.plusLighter` blending — additively summing the HUD
  /// onto the camera feed pixels. Emulates the real Meta Ray-Ban Display's
  /// additive optical surface (dark pixels = transparent, bright pixels =
  /// brighten what's behind). Single emulator-level switch; no per-element
  /// tweaks. Bright/sunny scenes will wash out the panels — expected, same
  /// behavior as the physical glasses.
  let additiveBlend: Bool
  /// Chooses the additive-mode panel recipe inside the lens. Defaults to the
  /// current standard surface so existing call sites, especially Coaching,
  /// remain visually unchanged.
  let additiveSurfaceVariant: HUDAdditiveSurfaceVariant
  /// When true, the lens captures double-taps on its background and
  /// dispatches them as `HUDInputEvent.dismiss` into the focus engine —
  /// the topmost handler decides what dismiss means in its context (step
  /// page → trigger exit overlay; overlay → cancel itself). Wire `true`
  /// from modes that install a handler stack (Coaching, Troubleshoot);
  /// leave `false` for modes that don't (Expert single-page recording).
  ///
  /// Once the MediaPipe `MicroGestureRecognizer` emits a doublePinch
  /// event, that gesture also dispatches `.dismiss` through the same
  /// pipeline — so handler `handleDismiss()` covers both touch and hand
  /// gestures from one declaration site.
  let enableDismissGesture: Bool
  @ViewBuilder let page: (Int) -> PageContent

  @StateObject private var hoverCoordinator = HUDHoverCoordinator()

  init(
    pageCount: Int,
    pageIndex: Binding<Int>,
    showBoundary: Bool = false,
    additiveBlend: Bool = false,
    additiveSurfaceVariant: HUDAdditiveSurfaceVariant = .standard,
    enableDismissGesture: Bool = false,
    @ViewBuilder page: @escaping (Int) -> PageContent
  ) {
    self.pageCount = pageCount
    self._pageIndex = pageIndex
    self.showBoundary = showBoundary
    self.additiveBlend = additiveBlend
    self.additiveSurfaceVariant = additiveSurfaceVariant
    self.enableDismissGesture = enableDismissGesture
    self.page = page
  }

  var body: some View {
    GeometryReader { geometry in
      let side = squareSide(for: geometry.size)
      let lensAlignment: Alignment = geometry.size.width > geometry.size.height ? .trailing : .center

      ZStack {
        // Scrim — clears hover on tap. Sits behind the lens so empty lens
        // area falls through to the host's drawer/chrome handle as usual.
        if hoverCoordinator.hovered != nil {
          Color.clear
            .contentShape(Rectangle())
            .onTapGesture { hoverCoordinator.cancel() }
            .ignoresSafeArea()
        }

        // The lens square — centered in portrait. Drops the previous
        // landscape `.scrollableViewport` branch entirely. In landscape,
        // pin to the trailing edge to match Meta Ray-Ban Display's
        // right-lens-only screen placement.
        squareLens(side: side)
          .frame(width: side, height: side)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: lensAlignment)
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .environmentObject(hoverCoordinator)
    // MediaPipe pinch-drag → focus engine. The recognizer lives in
    // `HandGestureService.shared`; we install our translator on the
    // service's dedicated focus-engine slot (independent of `onEvent` /
    // `onBackGesture` so mode-local hooks keep working). Always-on:
    // even modes without a handler stack get the wiring; their
    // dispatches are no-ops because the stack is empty.
    .onAppear {
      let coord = hoverCoordinator
      HandGestureService.shared.onFocusEngineEvent = { event in
        dispatchPinchDragEvent(event, into: coord)
      }
    }
    .onDisappear {
      HandGestureService.shared.onFocusEngineEvent = nil
    }
  }

  // MARK: - Lens

  @ViewBuilder
  private func squareLens(side: CGFloat) -> some View {
    ZStack {
      // Dismiss gesture: screen double-tap on lens "background" (areas not
      // covered by a hover-selectable element). The MediaPipe back gesture
      // (double index-finger pinch) dispatches `.dismiss` through the same
      // pipeline — see `HandGestureService.shared.onFocusEngineEvent`.
      // Topmost handler decides what dismiss means.
      if enableDismissGesture {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture(count: 2) {
            hoverCoordinator.dispatch(.dismiss)
          }
      }

      pageStack(side: side)

      if pageCount > 1 {
        VStack {
          Spacer()
          pageIndicator
            .padding(.bottom, RayBanHUDLayoutTokens.viewportInset / 2)
        }
      }
    }
    .frame(width: side, height: side)
    // The boundary that makes swipe-out animations correct: a card sliding
    // left disappears at the lens edge instead of translating off-canvas.
    .clipped(antialiased: true)
    // Propagate the compositing decision into the panel system so
    // `HUDSurfaceBackground` can swap to a dark "container" recipe under
    // additive (Google's transparent-screens guidance: dark surfaces avoid
    // halating into adjacent text; bright surfaces destroy legibility).
    .environment(\.hudAdditiveBlend, additiveBlend)
    .environment(\.hudAdditiveSurfaceVariant, additiveSurfaceVariant)
    // Compose the lens to an offscreen layer and additively blend it onto
    // the camera feed only when the user toggle is on. Applying the
    // modifiers conditionally (different view identity per branch) plus
    // a `.id` on the lens guarantees SwiftUI rebuilds the offscreen
    // layer when the toggle flips — without this, the `Coaching` scene
    // re-composed correctly but `Expert` and `Troubleshoot` cached the
    // old layer until a multitasking-driven full re-layout. See plan
    // notes for the diagnosis.
    .modifier(LensCompositingModifier(additiveBlend: additiveBlend))
    .id(LensCompositingIdentity(
      additiveBlend: additiveBlend,
      additiveSurfaceVariant: additiveSurfaceVariant
    ))
    .overlay {
      // Debug-only outline of the square. Drawn outside the clip so the
      // dashed stroke + size badge are always visible. Toggled via
      // `showBoundary` from the call site.
      if showBoundary {
        boundaryOverlay(side: side)
      }
    }
    // Touch swipe → directional input. Both axes — horizontal swipes
    // dispatch `.left` / `.right`, vertical dispatch `.up` / `.down`.
    // The topmost handler interprets per-page (step nav, focus traversal,
    // page nav, etc). Drops the previous direct `pageIndex` mutation so
    // semantics live with the handler, not the input transport.
    .gesture(
      DragGesture(minimumDistance: RayBanHUDLayoutTokens.stepSwipeMinimumDistance)
        .onEnded { value in
          dispatchDirectionalIfCommitted(from: value)
        }
    )
  }

  @ViewBuilder
  private func boundaryOverlay(side: CGFloat) -> some View {
    ZStack {
      Rectangle()
        .strokeBorder(
          Color(red: 1.0, green: 0.76, blue: 0.11),
          style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
        )

      VStack {
        HStack {
          Text("LENS · \(Int(side))×\(Int(side))")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              Capsule().fill(Color(red: 1.0, green: 0.76, blue: 0.11))
            )
          Spacer(minLength: 0)
        }
        Spacer(minLength: 0)
      }
      .padding(4)
    }
    .frame(width: side, height: side)
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private func pageStack(side: CGFloat) -> some View {
    if pageIndex >= 0, pageIndex < pageCount {
      page(pageIndex)
        .frame(width: side, height: side)
    }
  }

  private var pageIndicator: some View {
    HStack(spacing: RayBanHUDLayoutTokens.pageIndicatorSpacing) {
      ForEach(0..<pageCount, id: \.self) { idx in
        Circle()
          .fill(idx == pageIndex ? Color.white.opacity(0.95) : Color.white.opacity(0.32))
          .frame(
            width: RayBanHUDLayoutTokens.pageIndicatorDotDiameter,
            height: RayBanHUDLayoutTokens.pageIndicatorDotDiameter
          )
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .rayBanHUDPanel(shape: .capsule)
  }

  // MARK: - Geometry + gesture helpers

  private func squareSide(for size: CGSize) -> CGFloat {
    let shortEdge = min(size.width, size.height)
    return max(0, shortEdge - (RayBanHUDLayoutTokens.viewportInset * 2))
  }

  /// Translates a finger drag's commit translation to a `Direction` and
  /// dispatches into the focus engine if the threshold is crossed. The
  /// dominant axis (whichever has greater magnitude) wins. Below
  /// threshold = no-op (no snap-back animation needed; nothing was
  /// visually dragging).
  private func dispatchDirectionalIfCommitted(from value: DragGesture.Value) {
    let dx = value.translation.width
    let dy = value.translation.height
    let threshold = RayBanHUDLayoutTokens.stepSwipeCommitThreshold

    let direction: Direction?
    if abs(dx) > abs(dy) {
      if dx <= -threshold { direction = .left }
      else if dx >= threshold { direction = .right }
      else { direction = nil }
    } else {
      if dy <= -threshold { direction = .up }
      else if dy >= threshold { direction = .down }
      else { direction = nil }
    }

    guard let direction else { return }
    hoverCoordinator.dispatch(.directional(direction))
  }
}

private struct LensCompositingIdentity: Hashable {
  let additiveBlend: Bool
  let additiveSurfaceVariant: HUDAdditiveSurfaceVariant
}

/// Conditional `.compositingGroup() + .blendMode(.plusLighter)` wrapper.
/// Keeping the two modifier chains structurally distinct (different view
/// identity per branch) is what makes SwiftUI invalidate the offscreen
/// compositing layer when the additive toggle flips, so Expert and
/// Troubleshoot pick up the change live instead of waiting for a
/// multitasking-driven re-layout.
private struct LensCompositingModifier: ViewModifier {
  let additiveBlend: Bool

  func body(content: Content) -> some View {
    if additiveBlend {
      content
        .compositingGroup()
        .blendMode(.plusLighter)
    } else {
      content
    }
  }
}
