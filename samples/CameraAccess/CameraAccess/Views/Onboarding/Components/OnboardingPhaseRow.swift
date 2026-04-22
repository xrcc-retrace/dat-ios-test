import SwiftUI

struct OnboardingPhaseRow: View {
  let number: Int
  let icon: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.xl) {
      Text("\(number)")
        .font(.retraceFace(.semibold, size: 13))
        .foregroundColor(.textSecondary)
        .frame(width: 28, height: 28)
        .background(Color.surfaceRaised)
        .clipShape(Circle())

      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack(spacing: Spacing.md) {
          Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.textPrimary)
          Text(title)
            .font(.retraceTitle3)
            .foregroundColor(.textPrimary)
        }

        Text(detail)
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
  }
}
