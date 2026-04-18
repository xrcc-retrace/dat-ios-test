import SwiftUI

struct WorkflowListView: View {
  @StateObject private var viewModel = WorkflowListViewModel()
  @ObservedObject var wearablesVM: WearablesViewModel
  let onExit: () -> Void

  var body: some View {
    RetraceScreen {

      if viewModel.isLoading && viewModel.procedures.isEmpty {
        ProgressView()
          .scaleEffect(1.5)
          .tint(.appPrimary)
      } else if viewModel.procedures.isEmpty {
        emptyState
      } else {
        procedureList
      }
    }
    .navigationTitle("Workflows")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          onExit()
        } label: {
          Image(systemName: "chevron.backward")
            .foregroundColor(.textSecondary)
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink {
          ServerSettingsView(wearablesVM: wearablesVM)
        } label: {
          Image(systemName: "gearshape")
            .foregroundColor(.textSecondary)
        }
      }
    }
    .retraceNavBar()
    .navigationDestination(for: String.self) { procedureId in
      ProcedureDetailView(procedureId: procedureId)
    }
    .refreshable {
      await viewModel.fetchProcedures()
    }
    .task {
      await viewModel.fetchProcedures()
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    EmptyStateView(
      icon: "video.badge.plus",
      title: "No workflows yet",
      message: "Record your first procedure using your\nglasses or upload a video"
    )
  }

  // MARK: - Procedure List

  private var procedureList: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        // Summary strip
        HStack(spacing: Spacing.md) {
          MetadataPill(text: "\(viewModel.procedures.count) procedures")
          MetadataPill(text: "\(viewModel.totalStepCount) total steps")
          Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.md)

        // Procedure cards
        ForEach(viewModel.procedures) { procedure in
          NavigationLink(value: procedure.id) {
            ProcedureCardView(
              title: procedure.title,
              description: procedure.description,
              stepCount: procedure.stepCount ?? 0,
              duration: procedure.totalDuration,
              createdAt: procedure.createdAt,
              status: procedure.status
            )
          }
          .padding(.horizontal, Spacing.screenPadding)
        }
      }
      .padding(.bottom, Spacing.screenPadding)
    }
  }
}
