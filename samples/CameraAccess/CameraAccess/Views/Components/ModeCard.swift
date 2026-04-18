import SwiftUI

struct ModeCard: View {
  let icon: String
  let title: String
  let subtitle: String
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Spacing.xl) {
        Image(systemName: icon)
          .font(.system(size: 24))
          .foregroundColor(isEnabled ? .iconForeground : .textTertiary)
          .frame(width: 48, height: 48)
          .background(isEnabled ? Color.iconSurface : Color.surfaceRaised)
          .cornerRadius(Radius.md)

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(title)
            .font(.retraceTitle3)
            .foregroundColor(isEnabled ? .textPrimary : .textTertiary)
          Text(subtitle)
            .font(.retraceCallout)
            .foregroundColor(.textSecondary)
        }

        Spacer()

        if isEnabled {
          Image(systemName: "chevron.right")
            .font(.retraceSubheadline)
            .foregroundColor(.textTertiary)
        }
      }
      .padding(Spacing.xxl)
      .background(Color.surfaceBase)
      .cornerRadius(Radius.lg)
    }
    .buttonStyle(ScaleButtonStyle())
    .disabled(!isEnabled)
  }
}
