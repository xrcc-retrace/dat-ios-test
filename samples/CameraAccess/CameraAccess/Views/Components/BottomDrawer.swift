import SwiftUI

/// Reusable two-detent bottom drawer.
///
/// At rest only the handle (default 48pt) is visible; pull up to expand
/// to ~90% of the host height. Velocity-aware snap on release: a quick
/// flick up expands, a quick flick down collapses, otherwise the closest
/// detent wins.
///
/// The drag gesture lives on the handle strip only, so `ScrollView` /
/// `Button` interactions inside the drawer content are untouched — this
/// was the reason a native `.sheet` + `presentationDetents` was rejected.
///
/// Styling uses the app's shared `.glassPanel()` so the drawer blends
/// with the Retrace visual language and lets the camera bleed through the
/// ultraThinMaterial backdrop.
struct BottomDrawer<Content: View>: View {
  @Binding var isExpanded: Bool
  let handleHeight: CGFloat
  let expandedFraction: CGFloat
  let content: () -> Content

  @GestureState private var dragTranslation: CGFloat = 0

  init(
    isExpanded: Binding<Bool>,
    handleHeight: CGFloat = 48,
    expandedFraction: CGFloat = 0.9,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self._isExpanded = isExpanded
    self.handleHeight = handleHeight
    self.expandedFraction = expandedFraction
    self.content = content
  }

  var body: some View {
    GeometryReader { geo in
      let totalHeight = geo.size.height
      let expandedHeight = totalHeight * expandedFraction
      // Offsets are measured from the drawer's natural position (which is
      // its own top edge at y=0 inside the GeometryReader). We shift the
      // drawer down so only the handle peeks above the bottom edge, or up
      // so the full expanded height is visible.
      let collapsedOffset = totalHeight - handleHeight
      let expandedOffset = totalHeight - expandedHeight
      let baseOffset = isExpanded ? expandedOffset : collapsedOffset
      let unclamped = baseOffset + dragTranslation
      let clampedOffset = min(max(unclamped, expandedOffset), collapsedOffset)

      VStack(spacing: 0) {
        handleStrip

        content()
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .clipped()
      }
      .frame(maxWidth: .infinity)
      .frame(height: expandedHeight, alignment: .top)
      .glassPanel(cornerRadius: 28)
      .offset(y: clampedOffset)
      .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.85), value: isExpanded)
    }
    .ignoresSafeArea(edges: .bottom)
  }

  // MARK: - Handle

  private var handleStrip: some View {
    VStack(spacing: 0) {
      Capsule()
        .fill(Color.white.opacity(0.55))
        .frame(width: 40, height: 5)
        .padding(.top, 10)
        .padding(.bottom, 6)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity)
    .frame(height: handleHeight)
    .contentShape(Rectangle())
    .gesture(handleDrag)
  }

  private var handleDrag: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .global)
      .updating($dragTranslation) { value, state, _ in
        state = value.translation.height
      }
      .onEnded { value in
        // Predicted end location approximates post-release momentum; the
        // delta from current location gives us velocity in points.
        let velocityY = value.predictedEndLocation.y - value.location.y
        let translation = value.translation.height

        // Fast flick wins regardless of position.
        if velocityY < -300 {
          isExpanded = true
          return
        }
        if velocityY > 300 {
          isExpanded = false
          return
        }

        // Otherwise snap to whichever detent the drag ended nearer to.
        // Positive translation is downward drag.
        if isExpanded {
          isExpanded = translation < 100
        } else {
          isExpanded = translation < -100
        }
      }
  }
}
