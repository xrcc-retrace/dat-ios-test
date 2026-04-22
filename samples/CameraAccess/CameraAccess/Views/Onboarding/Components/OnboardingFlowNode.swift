import SwiftUI

struct OnboardingFlowNode: View {
  let icon: String
  let label: String
  let isActive: Bool

  var body: some View {
    VStack(spacing: Spacing.md) {
      Image(systemName: icon)
        .font(.system(size: 26, weight: .semibold))
        .foregroundColor(isActive ? .iconForeground : .textTertiary)
        .frame(width: 64, height: 64)
        .background(isActive ? Color.iconSurface : Color.surfaceBase)
        .cornerRadius(Radius.md)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md)
            .stroke(isActive ? Color.textPrimary.opacity(0.15) : .clear, lineWidth: 1)
        )

      Text(label)
        .font(.retraceCaption1)
        .foregroundColor(isActive ? .textPrimary : .textTertiary)
        .lineLimit(1)
    }
    .frame(width: 88)
    .animation(.easeInOut(duration: 0.25), value: isActive)
  }
}
