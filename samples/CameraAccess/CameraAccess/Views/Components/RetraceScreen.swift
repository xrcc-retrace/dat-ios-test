import SwiftUI

struct RetraceScreen<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    ZStack {
      Color.backgroundPrimary.edgesIgnoringSafeArea(.all)
      content()
    }
  }
}
