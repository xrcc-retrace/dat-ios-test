import SwiftUI

struct ControlsSection<Content: View>: View {
  let header: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text(header)
        .font(.retraceFace(.semibold, size: 11))
        .tracking(1.2)
        .foregroundColor(.textTertiary)
        .padding(.horizontal, Spacing.xs)

      CardView {
        content()
      }
    }
  }
}
