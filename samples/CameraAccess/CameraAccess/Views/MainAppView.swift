/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MainAppView.swift
//
// Central navigation hub that displays different views based on DAT SDK registration and device states.
// When unregistered, shows the registration flow. When registered, shows the device selection screen
// for choosing which Meta wearable device to stream from.
//

import MWDATCore
import SwiftUI

struct MainAppView: View {
  let wearables: WearablesInterface
  @ObservedObject private var viewModel: WearablesViewModel
  @ObservedObject private var discovery = BonjourDiscovery.shared
  @State private var showConnectedToast = false
  @AppStorage(OnboardingContainerView.completionKey) private var onboardingCompleted = false

  init(wearables: WearablesInterface, viewModel: WearablesViewModel) {
    self.wearables = wearables
    self.viewModel = viewModel
  }

  var body: some View {
    ZStack(alignment: .top) {
      // Root gate removed — the app runs end-to-end via iPhone without glasses
      // paired. Glasses-connection is checked at the exact moment the user
      // picks a glasses-backed action ("Record with Glasses" / "Coach with
      // Glasses"), which presents a registration sheet on demand.
      ModeSelectionView(wearables: wearables, wearablesVM: viewModel)

      if showConnectedToast {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundColor(.green)
          Text("Server Connected")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .zIndex(1)
      }
    }
    .onChange(of: discovery.discoveredURL) { _, newURL in
      guard newURL != nil else { return }
      withAnimation(.easeOut(duration: 0.3)) {
        showConnectedToast = true
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        withAnimation(.easeIn(duration: 0.3)) {
          showConnectedToast = false
        }
      }
    }
    .fullScreenCover(isPresented: Binding(
      get: { !onboardingCompleted },
      set: { presented in
        if !presented { onboardingCompleted = true }
      }
    )) {
      OnboardingContainerView(
        wearables: wearables,
        wearablesVM: viewModel,
        onComplete: { onboardingCompleted = true }
      )
    }
  }
}
