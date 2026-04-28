import SwiftUI

/// Slim, unlabeled 3-segment progress bar for the bottom of the
/// Troubleshoot lens. Each segment fills as the diagnostic flow
/// advances (Identify → Diagnose → Find a fix). The labeled iPhone-
/// side variant lives in `DiagnosticPhaseBar.swift`; this one is the
/// in-lens companion — strictly visual, no labels, no chrome.
struct DiagnosticPhaseLensBar: View {
  let phase: DiagnosticPhase

  private var activeIndex: Int {
    switch phase {
    case .discovering: return 0
    case .diagnosing:  return 1
    case .resolving:   return 2
    case .resolved:    return 2
    }
  }

  var body: some View {
    HStack(spacing: 6) {
      ForEach(0..<3, id: \.self) { i in
        Capsule()
          .fill(fillColor(for: i))
          .frame(height: 4)
          .animation(.easeInOut(duration: 0.3), value: activeIndex)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private func fillColor(for i: Int) -> Color {
    if i <= activeIndex { return Color.white.opacity(0.95) }
    return Color.white.opacity(0.18)
  }
}
