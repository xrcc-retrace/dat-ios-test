import SwiftUI

/// Three-segment labeled progress bar for the diagnostic flow.
/// Matches StepProgressBar's ink-on-ink visual vocabulary, extended
/// with inline segment labels ("Identifying" / "Diagnosing" / "Resolution").
struct DiagnosticPhaseBar: View {
  let phase: DiagnosticPhase

  private var activeIndex: Int {
    switch phase {
    case .discovering: return 0
    case .diagnosing:  return 1
    case .resolving:   return 2
    case .resolved:    return 2
    }
  }

  private static let labels = ["Identifying", "Diagnosing", "Resolution"]

  var body: some View {
    VStack(spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        ForEach(0..<3, id: \.self) { i in
          RoundedRectangle(cornerRadius: Radius.full)
            .fill(i <= activeIndex ? Color.textPrimary : Color.surfaceRaised)
            .frame(height: 4)
            .animation(.easeInOut(duration: 0.3), value: activeIndex)
        }
      }
      HStack {
        ForEach(0..<3, id: \.self) { i in
          Text(Self.labels[i])
            .font(.retraceCaption1)
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
