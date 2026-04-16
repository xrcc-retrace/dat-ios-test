import SwiftUI

struct WorkflowListView: View {
  @StateObject private var viewModel = WorkflowListViewModel()
  @Binding var navigateToProcedure: String?

  var body: some View {
    ZStack {
      Color.backgroundPrimary.edgesIgnoringSafeArea(.all)

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
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink {
          ServerSettingsView()
        } label: {
          Image(systemName: "gearshape")
            .foregroundColor(.textSecondary)
        }
      }
    }
    .toolbarBackground(.hidden, for: .navigationBar)
    .refreshable {
      await viewModel.fetchProcedures()
    }
    .task {
      await viewModel.fetchProcedures()
    }
    .navigationDestination(item: $navigateToProcedure) { procedureId in
      ProcedureDetailView(procedureId: procedureId)
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: Spacing.xl) {
      Image(systemName: "video.badge.plus")
        .font(.system(size: 48))
        .foregroundColor(.textTertiary)

      Text("No workflows yet")
        .font(.retraceTitle3)
        .foregroundColor(.textPrimary)

      Text("Record your first procedure using your\nglasses or upload a video")
        .font(.retraceCallout)
        .foregroundColor(.textSecondary)
        .multilineTextAlignment(.center)
    }
    .padding(Spacing.screenPadding)
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
          .contextMenu {
            Button(role: .destructive) {
              Task { await viewModel.deleteProcedure(id: procedure.id) }
            } label: {
              Label("Delete", systemImage: "trash")
            }
          }
          .padding(.horizontal, Spacing.screenPadding)
        }
      }
      .padding(.bottom, Spacing.screenPadding)
    }
    .navigationDestination(for: String.self) { procedureId in
      ProcedureDetailView(procedureId: procedureId)
    }
  }
}

extension String: @retroactive Identifiable {
  public var id: String { self }
}
