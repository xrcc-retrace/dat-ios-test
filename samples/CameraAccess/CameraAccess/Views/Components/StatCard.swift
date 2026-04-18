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
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      Text(label)
        .font(.retraceCaption1)
        .foregroundColor(.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
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
