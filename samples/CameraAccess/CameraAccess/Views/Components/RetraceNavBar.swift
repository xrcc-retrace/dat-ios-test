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

    let buttonAppearance = UIBarButtonItemAppearance()
    buttonAppearance.normal.titleTextAttributes = [.foregroundColor: fg]
    buttonAppearance.highlighted.titleTextAttributes = [.foregroundColor: fg]
    buttonAppearance.focused.titleTextAttributes = [.foregroundColor: fg]
    appearance.buttonAppearance = buttonAppearance
    appearance.doneButtonAppearance = buttonAppearance
    appearance.backButtonAppearance = buttonAppearance

    UINavigationBar.appearance().standardAppearance = appearance
    UINavigationBar.appearance().scrollEdgeAppearance = appearance
    UINavigationBar.appearance().compactAppearance = appearance
    UINavigationBar.appearance().compactScrollEdgeAppearance = appearance
    UINavigationBar.appearance().tintColor = fg

    let segmented = UISegmentedControl.appearance()
    segmented.selectedSegmentTintColor = fg
    segmented.setTitleTextAttributes([.foregroundColor: fg], for: .normal)
    segmented.setTitleTextAttributes([.foregroundColor: bg], for: .selected)
    segmented.setTitleTextAttributes([.foregroundColor: fg], for: .highlighted)
  }
}

extension View {
  func retraceNavBar() -> some View {
    self
      .toolbarBackground(Color.backgroundPrimary, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .tint(Color.textPrimary)
  }
}
