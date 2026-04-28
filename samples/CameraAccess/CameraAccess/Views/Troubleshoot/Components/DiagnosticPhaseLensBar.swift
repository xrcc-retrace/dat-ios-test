import SwiftUI

/// Slim, unlabeled 3-segment phase indicator for the top of the
/// Troubleshoot lens. Each segment fills as the diagnostic flow
/// advances (Identify -> Diagnose -> Find a fix). The labeled iPhone-
/// side variant lives in `DiagnosticPhaseBar.swift`; this one is the
/// in-lens companion: strictly visual, no labels, no chrome.
struct DiagnosticPhaseLensBar: View {
  let phase: DiagnosticPhase
  let widthFraction: CGFloat

  init(phase: DiagnosticPhase, widthFraction: CGFloat = 0.5) {
    self.phase = phase
    self.widthFraction = widthFraction
  }

  private var activeIndex: Int {
    switch phase {
    case .discovering: return 0
    case .diagnosing:  return 1
    case .resolving:   return 2
    case .resolved:    return 2
    }
  }

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 6) {
        ForEach(0..<3, id: \.self) { i in
          Capsule()
            .fill(fillColor(for: i))
            .frame(height: 4)
            .animation(.easeInOut(duration: 0.3), value: activeIndex)
        }
      }
      .frame(width: geometry.size.width * normalizedWidthFraction)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 4)
  }

  private var normalizedWidthFraction: CGFloat {
    min(1, max(0.1, widthFraction))
  }

  private func fillColor(for i: Int) -> Color {
    if i <= activeIndex { return Color.white.opacity(0.95) }
    return Color.white.opacity(0.18)
  }
}
