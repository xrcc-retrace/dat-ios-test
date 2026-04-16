import SwiftUI

struct GlassPanel: ViewModifier {
  var cornerRadius: CGFloat = Radius.xl

  func body(content: Content) -> some View {
    content
      .background(.ultraThinMaterial)
      .cornerRadius(cornerRadius)
      .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
  }
}

extension View {
  func glassPanel(cornerRadius: CGFloat = Radius.xl) -> some View {
    modifier(GlassPanel(cornerRadius: cornerRadius))
  }
}
