import MWDATCore
import SwiftUI

struct ExpertTabView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @State private var selectedTab = 0
  @State private var navigateToProcedure: String?

  var body: some View {
    TabView(selection: $selectedTab) {
      // Tab 1: Workflows
      NavigationStack {
        WorkflowListView(
          navigateToProcedure: $navigateToProcedure
        )
      }
      .tabItem {
        Image(systemName: "list.bullet.rectangle.portrait")
        Text("Workflows")
      }
      .tag(0)

      // Tab 2: Record
      NavigationStack {
        RecordTabView(
          wearables: wearables,
          wearablesVM: wearablesVM,
          onProcedureCreated: { procedureId in
            navigateToProcedure = procedureId
            selectedTab = 0
          }
        )
      }
      .tabItem {
        Image(systemName: "video.badge.plus")
        Text("Record")
      }
      .tag(1)
    }
    .tint(.appPrimary)
    .toolbarBackground(Color.backgroundSecondary, for: .tabBar)
    .toolbarBackground(.visible, for: .tabBar)
  }
}
