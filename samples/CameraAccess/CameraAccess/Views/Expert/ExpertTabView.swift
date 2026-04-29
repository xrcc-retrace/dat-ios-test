import MWDATCore
import SwiftUI

struct ExpertTabView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  let onExit: () -> Void
  @State private var selectedTab = 0
  @State private var workflowsPath = NavigationPath()

  // Owned here (rather than on `RecordTabView`) so post-completion
  // observers can fire even when the user is on the Workflows tab. The
  // background-upload escape hatches in both flows ("Keep working in the
  // background") rely on this — see `autoPoppedVideoResult` below.
  @StateObject private var uploadService = UploadService()
  @StateObject private var manualUploadVM = ManualUploadViewModel()

  /// Drives the auto-pop of `ProcedureReviewView` when a backgrounded
  /// video upload completes. Set from the `.onChange` observer below;
  /// cleared by the cover's lifecycle and on confirm/cancel.
  @State private var autoPoppedVideoResult: ProcedureResponse?

  var body: some View {
    TabView(selection: $selectedTab) {
      // Tab 1: Record
      NavigationStack {
        RecordTabView(
          wearables: wearables,
          wearablesVM: wearablesVM,
          onProcedureCreated: { procedureId in
            workflowsPath.append(procedureId)
            selectedTab = 1
          },
          onExit: onExit,
          uploadService: uploadService,
          manualUploadVM: manualUploadVM
        )
      }
      .tabItem {
        Image(systemName: "video.badge.plus")
        Text("Record")
      }
      .tag(0)

      // Tab 2: Workflows
      NavigationStack(path: $workflowsPath) {
        WorkflowListView(
          wearablesVM: wearablesVM,
          onExit: onExit
        )
      }
      .tabItem {
        Image(systemName: "list.bullet.rectangle.portrait")
        Text("Workflows")
      }
      .tag(1)
    }
    .tint(.textPrimary)
    .toolbarBackground(Color.backgroundPrimary, for: .tabBar)
    .toolbarBackground(.visible, for: .tabBar)
    .toolbarColorScheme(.dark, for: .tabBar)
    // Auto-pop the video result review when a backgrounded upload
    // finishes processing. Gated on `wasBackgrounded` so the in-cover
    // path (user stayed in `ExpertRecordingReviewView` until the result
    // arrived and tapped the existing "Review workflow" link) doesn't
    // double-present.
    .onChange(of: uploadService.uploadResult) { _, newResult in
      guard let result = newResult, uploadService.wasBackgrounded else { return }
      autoPoppedVideoResult = result
    }
    // Auto-navigate to the workflow detail when a backgrounded manual
    // import lands on `.ready`. Gated on `wasBackgrounded` so the
    // in-sheet completion path (`ExpertManualUploadSheet.onComplete`)
    // doesn't double-fire.
    .onChange(of: manualUploadVM.phase) { _, newPhase in
      guard manualUploadVM.wasBackgrounded,
            case let .ready(procedureId) = newPhase else { return }
      workflowsPath.append(procedureId)
      selectedTab = 1
      // Reset to `.idle` so the observer doesn't refire on lingering state.
      manualUploadVM.cancel()
    }
    .fullScreenCover(item: $autoPoppedVideoResult) { result in
      NavigationStack {
        ProcedureReviewView(
          initialProcedure: result,
          serverBaseURL: uploadService.serverBaseURL,
          onConfirmed: {
            workflowsPath.append(result.id)
            selectedTab = 1
            uploadService.reset()
            autoPoppedVideoResult = nil
          },
          onCanceled: {
            uploadService.reset()
            autoPoppedVideoResult = nil
          }
        )
      }
    }
  }
}
