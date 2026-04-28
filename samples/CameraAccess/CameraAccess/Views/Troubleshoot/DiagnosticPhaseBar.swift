import SwiftUI

/// Three-segment labeled progress bar for the diagnostic flow.
/// Matches StepProgressBar's ink-on-ink visual vocabulary, extended
/// with inline icon + segment labels matching the landing page
/// convention ("Identify" / "Diagnose" / "Find a fix").
struct DiagnosticPhaseBar: View {
  let phase: DiagnosticPhase

  private struct Segment {
    let icon: String
    let label: String
  }

  private static let segments: [Segment] = [
    Segment(icon: "camera.viewfinder", label: "Identify"),
    Segment(icon: "magnifyingglass",   label: "Diagnose"),
    Segment(icon: "globe",             label: "Find a fix"),
  ]

  private var activeIndex: Int {
    switch phase {
    case .discovering: return 0
    case .diagnosing:  return 1
    case .resolving:   return 2
    case .resolved:    return 2
    }
  }

  var body: some View {
    VStack(spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        ForEach(0..<3, id: \.self) { i in
          RoundedRectangle(cornerRadius: Radius.full)
            // Unfilled segments are a solid dark gray so the user can
            // see at a glance which phase they're in: bright white
            // (active) vs dark gray (not yet reached). Solid `white:
            // 0.22` reads as unambiguously dark gray on top of any
            // camera passthrough, where the previous `surfaceRaised`
            // (#374151) blended into bright scenes and `black.opacity`
            // disappeared on dark scenes.
            .fill(i <= activeIndex ? Color.textPrimary : Color(white: 0.22))
            .frame(height: 4)
            .animation(.easeInOut(duration: 0.3), value: activeIndex)
        }
      }
      HStack(spacing: 0) {
        ForEach(0..<3, id: \.self) { i in
          HStack(spacing: 4) {
            Image(systemName: Self.segments[i].icon)
              .font(.system(size: 10, weight: .semibold))
            Text(Self.segments[i].label)
              .font(.retraceCaption1)
          }
          .foregroundColor(colorFor(i))
          .frame(maxWidth: .infinity, alignment: .center)
        }
      }
    }
  }

  private func colorFor(_ i: Int) -> Color {
    if i == activeIndex { return .textPrimary }
    if i < activeIndex { return .textSecondary }
    return .textTertiary
  }
}
