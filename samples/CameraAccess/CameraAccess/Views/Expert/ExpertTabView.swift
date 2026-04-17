import MWDATCore
import SwiftUI

struct ExpertTabView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @State private var selectedTab = 0
  @State private var navigateToProcedure: String?

  var body: some View {
    TabView(selection: $selectedTab) {
      // Tab 1: Record
      NavigationStack {
        RecordTabView(
          wearables: wearables,
          wearablesVM: wearablesVM,
          onProcedureCreated: { procedureId in
            navigateToProcedure = procedureId
            selectedTab = 1
          }
        )
      }
      .tabItem {
        Image(systemName: "video.badge.plus")
        Text("Record")
      }
      .tag(0)

      // Tab 2: Workflows
      NavigationStack {
        WorkflowListView(
          navigateToProcedure: $navigateToProcedure
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
