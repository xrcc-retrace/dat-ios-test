import SwiftUI

struct CategoryChip: View {
  let title: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.retraceSubheadline)
        .foregroundColor(isSelected ? .backgroundPrimary : .textSecondary)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(isSelected ? Color.textPrimary : Color.surfaceBase)
        .cornerRadius(Radius.full)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.full)
            .stroke(
              isSelected ? Color.clear : Color.borderSubtle,
              lineWidth: 1
            )
        )
    }
  }
}
