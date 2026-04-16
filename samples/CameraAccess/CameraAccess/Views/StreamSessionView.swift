/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionView.swift
//
//

import MWDATCore
import SwiftUI

struct StreamSessionView: View {
  let wearables: WearablesInterface
  @ObservedObject private var wearablesViewModel: WearablesViewModel
  @StateObject private var viewModel: StreamSessionViewModel
  let onAcknowledgeProcedure: () -> Void

  init(
    wearables: WearablesInterface,
    wearablesVM: WearablesViewModel,
    uploadService: UploadService,
    onAcknowledgeProcedure: @escaping () -> Void
  ) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables, uploadService: uploadService))
    self.onAcknowledgeProcedure = onAcknowledgeProcedure
  }

  var body: some View {
    ZStack {
      if viewModel.isStreaming {
        // Full-screen video view with streaming controls
        StreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      } else {
        // Pre-streaming setup view with permissions and start button
        NonStreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      }
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") {
        viewModel.dismissError()
      }
    } message: {
      Text(viewModel.errorMessage)
    }
    // Presented at the session level so it survives the switch from StreamView → NonStreamView
    // when "Stop recording" stops streaming and opens the upload page in one tap.
    .sheet(isPresented: $viewModel.showRecordingReview) {
      if let recordingURL = viewModel.recordingManager.recordingURL {
        ExpertRecordingReviewView(
          recordingURL: recordingURL,
          duration: viewModel.recordingManager.recordingDuration,
          uploadService: viewModel.uploadService,
          onDismiss: {
            viewModel.showRecordingReview = false
          },
          onAcknowledgeResult: onAcknowledgeProcedure
        )
      }
    }
  }
}
