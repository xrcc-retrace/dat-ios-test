import SwiftUI

struct CoachingStyleTile: View {
  let icon: String
  let name: String
  let description: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: Spacing.xl) {
        Image(systemName: icon)
          .font(.system(size: 22, weight: .semibold))
          .foregroundColor(isSelected ? .iconForeground : .textSecondary)
          .frame(width: 44, height: 44)
          .background(isSelected ? Color.iconSurface : Color.surfaceRaised)
          .cornerRadius(Radius.md)

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(name)
            .font(.retraceTitle3)
            .foregroundColor(.textPrimary)
          Text(description)
            .font(.retraceCallout)
            .foregroundColor(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        }

        Spacer(minLength: 0)

        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22))
          .foregroundColor(isSelected ? .textPrimary : .textTertiary)
      }
      .padding(Spacing.xl)
      .background(Color.surfaceBase)
      .cornerRadius(Radius.lg)
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg)
          .stroke(isSelected ? Color.textPrimary : .clear, lineWidth: 1)
      )
    }
    .buttonStyle(ScaleButtonStyle())
    .animation(.easeInOut(duration: 0.2), value: isSelected)
  }
}
