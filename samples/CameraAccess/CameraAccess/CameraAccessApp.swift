/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CameraAccessApp.swift
//
// Main entry point for the CameraAccess sample app demonstrating the Meta Wearables DAT SDK.
// This app shows how to connect to wearable devices (like Ray-Ban Meta smart glasses),
// stream live video from their cameras, and capture photos. It provides a complete example
// of DAT SDK integration including device registration, permissions, and media streaming.
//

import Foundation
import MWDATCore
import SwiftUI

#if DEBUG
import MWDATMockDevice
#endif

@main
struct CameraAccessApp: App {
  @UIApplicationDelegateAdaptor(RetraceAppDelegate.self) private var appDelegate
  @StateObject private var appOrientationController = AppOrientationController.shared

  private let wearables: WearablesInterface
  @StateObject private var wearablesViewModel: WearablesViewModel

  init() {
    RetraceNavBarAppearance.install()

    URLCache.shared = URLCache(
      memoryCapacity:  16 * 1024 * 1024,
      diskCapacity:   256 * 1024 * 1024,
      diskPath:       "RetraceURLCache"
    )

    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("--ui-testing-reset-onboarding") {
      UserDefaults.standard.removeObject(forKey: OnboardingContainerView.completionKey)
    } else if arguments.contains("--ui-testing-complete-onboarding") {
      UserDefaults.standard.set(true, forKey: OnboardingContainerView.completionKey)
    }

    do {
      try Wearables.configure()
    } catch {
      #if DEBUG
      NSLog("[CameraAccess] Failed to configure Wearables SDK: \(error)")
      #endif
    }

    #if DEBUG
    // Auto-configure MockDeviceKit when launched by XCUITests
    if arguments.contains("--ui-testing") {
      let device = MockDeviceKit.shared.pairRaybanMeta()

      let cameraKit = device.services.camera
      Task {
        guard let videoURL = Bundle.main.url(forResource: "plant", withExtension: "mp4"),
          let imageURL = Bundle.main.url(forResource: "plant", withExtension: "png")
        else {
          fatalError("Test resources not found - are you running a Release build?")
        }
        await cameraKit.setCameraFeed(fileURL: videoURL)
        await cameraKit.setCapturedImage(fileURL: imageURL)

        device.powerOn()
        device.don()
      }
    }
    #endif

    // Start Bonjour discovery for the Retrace server
    BonjourDiscovery.shared.startBrowsing()

    let wearables = Wearables.shared
    self.wearables = wearables
    self._wearablesViewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      MainAppView(wearables: Wearables.shared, viewModel: wearablesViewModel)
        .environmentObject(appOrientationController)
        .preferredColorScheme(.dark)
        .alert("Error", isPresented: $wearablesViewModel.showError) {
          Button("OK") {
            wearablesViewModel.dismissError()
          }
        } message: {
          Text(wearablesViewModel.errorMessage)
        }
        .overlay {
          RegistrationView(viewModel: wearablesViewModel)
        }
    }
  }
}
