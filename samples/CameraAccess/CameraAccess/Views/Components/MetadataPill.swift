import SwiftUI

struct MetadataPill: View {
  let icon: String?
  let text: String

  init(icon: String? = nil, text: String) {
    self.icon = icon
    self.text = text
  }

  var body: some View {
    HStack(spacing: Spacing.xs) {
      if let icon {
        Image(systemName: icon)
          .font(.system(size: 10))
          .foregroundColor(.textTertiary)
      }
      Text(text)
        .font(.retraceCaption1)
    }
    .foregroundColor(.textSecondary)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .background(Color.surfaceRaised)
    .cornerRadius(Radius.sm)
  }
}
