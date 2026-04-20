import SwiftUI
import UIKit

/// App-level orientation gate. The app ships portrait-locked by default; the
/// iPhone coaching flow temporarily broadens the allowed-orientation mask so
/// the user can rotate naturally into landscape for the Ray-Ban HUD
/// simulation. Coaching does NOT force-rotate the scene on entry — whatever
/// orientation the phone is already in is the orientation the session opens
/// in. Everything else stays portrait.
///
/// Wiring: a shared instance is owned by `RetraceAppDelegate`; SwiftUI views
/// reach it via `@EnvironmentObject`. The delegate overrides
/// `application(_:supportedInterfaceOrientationsFor:)` and returns whatever
/// `currentMask` the controller publishes. `lock(...)` remains available for
/// callers that genuinely need to force a rotation, but coaching no longer
/// uses it on entry — it calls `setAllowed(...)` instead.
@MainActor
final class AppOrientationController: ObservableObject {
  static let shared = AppOrientationController()

  @Published private(set) var currentMask: UIInterfaceOrientationMask = .portrait

  private init() {}

  func lock(_ mask: UIInterfaceOrientationMask) {
    currentMask = mask
    requestGeometryUpdate(mask)
  }

  /// Broaden (or narrow) the allowed-orientation mask without asking the
  /// scene to rotate. Used by the coaching flow on entry so the user can
  /// rotate the device naturally between portrait and landscape without
  /// ever forcing an initial rotation.
  func setAllowed(_ mask: UIInterfaceOrientationMask) {
    currentMask = mask
  }

  func unlock() {
    currentMask = .portrait
    requestGeometryUpdate(.portrait)
  }

  private func requestGeometryUpdate(_ mask: UIInterfaceOrientationMask) {
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive })
      ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
    else { return }

    let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
    scene.requestGeometryUpdate(preferences) { error in
      print("[AppOrientation] requestGeometryUpdate failed: \(error)")
    }
    UIViewController.attemptRotationToDeviceOrientation()
  }
}

/// UIKit delegate that defers allowed orientations to `AppOrientationController`.
final class RetraceAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    return AppOrientationController.shared.currentMask
  }
}
