import SwiftUI

// Generic accent-bordered hero card. Used as the primary action on
// landing screens (e.g. Expert Record, Troubleshoot Diagnose).
struct AccentedHeroCard: View {
  let icon: String
  let title: String
  let subtitle: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: Spacing.xl) {
        ZStack {
          Circle()
            .fill(Color.appPrimary.opacity(0.18))
            .frame(width: 64, height: 64)
          Image(systemName: icon)
            .font(.system(size: 30, weight: .semibold))
            .foregroundColor(.appPrimary)
        }

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(title)
            .font(.retraceTitle2)
            .foregroundColor(.textPrimary)
          Text(subtitle)
            .font(.retraceCallout)
            .foregroundColor(.textSecondary)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 0)

        Image(systemName: "chevron.right")
          .font(.retraceSubheadline)
          .foregroundColor(.textTertiary)
      }
      .padding(Spacing.xxl)
      .background(Color.surfaceBase)
      .cornerRadius(Radius.xl)
      .overlay(
        RoundedRectangle(cornerRadius: Radius.xl)
          .stroke(Color.appPrimary.opacity(0.35), lineWidth: 1.5)
      )
    }
    .buttonStyle(ScaleButtonStyle())
  }
}
