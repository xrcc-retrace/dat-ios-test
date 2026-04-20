import SwiftUI
import UIKit

enum RetraceNavBarAppearance {
  static func install() {
    let bg = UIColor(named: "backgroundPrimary") ?? .black
    let fg = UIColor(named: "textPrimary") ?? .white

    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = bg
    appearance.backgroundEffect = nil
    appearance.shadowColor = .clear
    appearance.shadowImage = UIImage()
    appearance.titleTextAttributes = [.foregroundColor: fg]
    appearance.largeTitleTextAttributes = [.foregroundColor: fg]

    UINavigationBar.appearance().standardAppearance = appearance
    UINavigationBar.appearance().scrollEdgeAppearance = appearance
    UINavigationBar.appearance().compactAppearance = appearance
    UINavigationBar.appearance().compactScrollEdgeAppearance = appearance
    UINavigationBar.appearance().tintColor = fg
  }
}

extension View {
  func retraceNavBar() -> some View {
    self
      .toolbarBackground(Color.backgroundPrimary, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
  }
}
