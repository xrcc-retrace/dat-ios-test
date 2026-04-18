import MWDATCore
import SwiftUI

struct LearnerTabView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  let onExit: () -> Void
  @StateObject private var progressStore = LocalProgressStore()

  var body: some View {
    TabView {
      // Tab 1: Procedures
      NavigationStack {
        DiscoverView(
          wearables: wearables,
          wearablesVM: wearablesVM,
          progressStore: progressStore,
          onExit: onExit
        )
      }
      .tabItem {
        Image(systemName: "wrench.and.screwdriver")
        Text("Procedures")
      }

      // Tab 2: Library
      NavigationStack {
        LibraryView(
          progressStore: progressStore,
          wearables: wearables,
          wearablesVM: wearablesVM,
          onExit: onExit
        )
      }
      .tabItem {
        Image(systemName: "books.vertical")
        Text("Library")
      }

      // Tab 3: Progress
      NavigationStack {
        LearnerProgressView(progressStore: progressStore, onExit: onExit)
      }
      .tabItem {
        Image(systemName: "chart.bar")
        Text("Progress")
      }

      // Tab 4: Profile
      NavigationStack {
        ProfileView(wearablesVM: wearablesVM, onExit: onExit)
      }
      .tabItem {
        Image(systemName: "person.circle")
        Text("Profile")
      }
    }
    .tint(.textPrimary)
    .toolbarBackground(Color.backgroundPrimary, for: .tabBar)
    .toolbarBackground(.visible, for: .tabBar)
  }
}
