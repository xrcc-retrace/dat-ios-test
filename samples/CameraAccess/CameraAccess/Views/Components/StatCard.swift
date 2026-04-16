import SwiftUI

struct StatCard: View {
  let value: String
  let label: String

  var body: some View {
    VStack(spacing: Spacing.xs) {
      Text(value)
        .font(.retraceTitle2)
        .fontWeight(.bold)
        .foregroundColor(.textPrimary)
      Text(label)
        .font(.retraceCaption1)
        .foregroundColor(.textSecondary)
    }
    .frame(maxWidth: .infinity)
    .padding(Spacing.xl)
    .background(Color.surfaceBase)
    .cornerRadius(Radius.md)
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
  }
}
