import SwiftUI

extension View {
  func retraceNavBar() -> some View {
    self
      .toolbarBackground(Color.backgroundPrimary, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
  }
}
