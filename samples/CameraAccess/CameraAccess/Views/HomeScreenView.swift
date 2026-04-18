/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATCore
import SwiftUI

struct HomeScreenView: View {
  @ObservedObject var viewModel: WearablesViewModel

  var body: some View {
    RetraceScreen {

      VStack(spacing: Spacing.lg) {
        Spacer()

        Image(.cameraAccessIcon)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 120)

        VStack(spacing: Spacing.lg) {
          HomeTipItemView(
            resource: .smartGlassesIcon,
            title: "Video Capture",
            text: "Record videos directly from your glasses, from your point of view."
          )
          HomeTipItemView(
            resource: .soundIcon,
            title: "Open-Ear Audio",
            text: "Hear notifications while keeping your ears open to the world around you."
          )
          HomeTipItemView(
            resource: .walkingIcon,
            title: "Enjoy On-the-Go",
            text: "Stay hands-free while you move through your day. Move freely, stay connected."
          )
        }

        Spacer()

        VStack(spacing: Spacing.xxl) {
          Text("You'll be redirected to the Meta AI app to confirm your connection.")
            .font(.retraceCallout)
            .foregroundColor(.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Spacing.lg)

          CustomButton(
            title: viewModel.registrationState == .registering ? "Connecting..." : "Connect my glasses",
            style: .primary,
            isDisabled: viewModel.registrationState == .registering
          ) {
            viewModel.connectGlasses()
          }
        }
      }
      .padding(.all, Spacing.screenPadding)
    }
  }
}

struct HomeTipItemView: View {
  let resource: ImageResource
  let title: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.lg) {
      Image(resource)
        .resizable()
        .renderingMode(.template)
        .foregroundColor(.textPrimary)
        .aspectRatio(contentMode: .fit)
        .frame(width: 24)
        .padding(.leading, Spacing.xs)
        .padding(.top, Spacing.xs)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text(title)
          .font(.retraceTitle3)
          .foregroundColor(.textPrimary)

        Text(text)
          .font(.retraceBody)
          .foregroundColor(.textSecondary)
      }
      Spacer()
    }
  }
}
