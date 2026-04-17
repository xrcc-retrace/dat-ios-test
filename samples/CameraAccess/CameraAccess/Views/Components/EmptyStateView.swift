import SwiftUI

struct EmptyStateView: View {
  let icon: String
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: icon)
        .font(.system(size: 36))
        .foregroundColor(.textTertiary)
      Text(title)
        .font(.retraceHeadline)
        .foregroundColor(.textPrimary)
      Text(message)
        .font(.retraceSubheadline)
        .foregroundColor(.textSecondary)
        .multilineTextAlignment(.center)
    }
    .padding(Spacing.screenPadding)
    .frame(maxWidth: .infinity)
  }
}
