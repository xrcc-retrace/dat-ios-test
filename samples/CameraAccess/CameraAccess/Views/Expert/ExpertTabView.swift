import MWDATCore
import SwiftUI

struct ExpertTabView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  let onExit: () -> Void
  @State private var selectedTab = 0
  @State private var workflowsPath = NavigationPath()

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
          onExit: onExit
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
  }
}
