import SwiftUI

struct ControlRow: View {
  let icon: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.xl) {
      Image(systemName: icon)
        .font(.system(size: 20, weight: .semibold))
        .foregroundColor(.textPrimary)
        .frame(width: 44, height: 44)
        .background(Color.surfaceRaised)
        .cornerRadius(Radius.sm)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(title)
          .font(.retraceHeadline)
          .foregroundColor(.textPrimary)
        Text(detail)
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.lg)
    .accessibilityElement(children: .combine)
  }
}
