import SwiftUI

struct ProcedureDetailView: View {
  let procedureId: String

  @StateObject private var viewModel = ProcedureDetailViewModel()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    RetraceScreen {
      content
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("Workflow")
    .retraceNavBar()
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          if let procedure = viewModel.procedure {
            NavigationLink {
              ProcedureEditView(procedure: procedure) {
                Task { await viewModel.fetchProcedure(id: procedureId) }
              }
            } label: {
              Label("Edit", systemImage: "pencil")
            }
          }

          Button(role: .destructive) {
            viewModel.showDeleteConfirmation = true
          } label: {
            Label("Delete", systemImage: "trash")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .foregroundColor(.textPrimary)
        }
      }
    }
    .alert("Delete Procedure", isPresented: $viewModel.showDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        Task {
          if await viewModel.deleteProcedure() {
            dismiss()
          }
        }
      }
    } message: {
      Text("This procedure and all its clips will be permanently deleted.")
    }
    .task {
      await viewModel.fetchProcedure(id: procedureId)
    }
  }

  @ViewBuilder
  private var content: some View {
    if viewModel.isLoading && viewModel.procedure == nil {
      ProgressView()
        .scaleEffect(1.5)
        .tint(.textPrimary)
    } else if let procedure = viewModel.procedure {
      ProcedureChapterDetailContent(
        procedure: procedure,
        serverBaseURL: viewModel.serverBaseURL,
        metrics: expertMetrics(for: procedure),
        readMoreContent: expertReadMoreContent(for: procedure),
        headerActionContent: EmptyView(),
        expandedStepFooter: { step in
          expertStepFooter(for: step)
        }
      )
    } else if let error = viewModel.errorMessage {
      VStack(spacing: Spacing.lg) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 36))
          .foregroundColor(.textPrimary)

        Text(error)
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
          .multilineTextAlignment(.center)
      }
      .padding(Spacing.screenPadding)
    }
  }

  private func expertMetrics(for procedure: ProcedureResponse) -> [ProcedureMetricItem] {
    ProcedureMetricItem.workflowSummary(
      duration: procedure.totalDuration,
      stepCount: procedure.steps.count,
      completionCount: placeholderCompletionCount
    )
  }

  private var placeholderCompletionCount: Int {
    // Placeholder until procedure-level analytics are available from the backend.
    142
  }

  @ViewBuilder
  private func expertReadMoreContent(for procedure: ProcedureResponse) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Divider()
        .background(Color.borderSubtle)

      HStack(spacing: Spacing.md) {
        MetadataPill(icon: "calendar", text: ProcedureDisplayFormat.date(procedure.createdAt))

        if let status = procedure.status, !status.isEmpty {
          MetadataPill(icon: "sparkles", text: status.capitalized)
        }
      }

      Text("Use the overflow menu to edit the workflow, or jump into a step below to revise that section in place.")
        .font(.retraceSubheadline)
        .foregroundColor(.textSecondary)
    }
  }

  @ViewBuilder
  private func expertStepFooter(for step: ProcedureStepResponse) -> some View {
    HStack {
      Spacer()

      NavigationLink {
        StepEditView(
          procedureId: procedureId,
          step: step
        ) {
          Task { await viewModel.fetchProcedure(id: procedureId) }
        }
      } label: {
        Label("Edit step", systemImage: "pencil")
          .font(.retraceSubheadline)
          .foregroundColor(.textPrimary)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm)
          .background(Color.surfaceRaised)
          .clipShape(Capsule())
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }
}
