/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import SwiftUI

struct CircleButton: View {
  let icon: String
  let text: String?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      if let text {
        VStack(spacing: Spacing.xxs) {
          Image(systemName: icon)
            .font(.retraceCallout)
          Text(text)
            .font(.system(size: 10, weight: .medium))
        }
      } else {
        Image(systemName: icon)
          .font(.retraceHeadline)
      }
    }
    .foregroundColor(Color.backgroundPrimary)
    .frame(width: 56, height: 56)
    .background(Color.textPrimary)
    .clipShape(Circle())
  }
}
