import MWDATCore
import SwiftUI

struct LibraryView: View {
  @ObservedObject var progressStore: LocalProgressStore
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  let onExit: () -> Void
  @State private var selectedSegment = 0
  @StateObject private var viewModel = LibraryViewModel()

  var body: some View {
    RetraceScreen {

      VStack(spacing: 0) {
        Picker("", selection: $selectedSegment) {
          Text("Saved").tag(0)
          Text("History").tag(1)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.lg)

        if selectedSegment == 0 {
          savedSection
        } else {
          historySection
        }
      }
      .frame(maxHeight: .infinity, alignment: .top)
    }
    .navigationTitle("My Library")
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
    }
    .retraceNavBar()
    .task {
      await viewModel.loadSaved(ids: progressStore.savedProcedureIDs)
    }
    .onChange(of: progressStore.savedProcedureIDs) { _, newIDs in
      Task { await viewModel.loadSaved(ids: newIDs) }
    }
  }

  // MARK: - Saved

  @ViewBuilder
  private var savedSection: some View {
    if viewModel.isLoading {
      Spacer()
      ProgressView().tint(.appPrimary)
      Spacer()
    } else if viewModel.savedProcedures.isEmpty {
      EmptyStateView(
        icon: "bookmark.slash",
        title: "No saved procedures",
        message: "Discover procedures and save them here"
      )
    } else {
      ScrollView {
        VStack(spacing: Spacing.lg) {
          ForEach(viewModel.savedProcedures) { procedure in
            NavigationLink {
              LearnerProcedureDetailView(
                procedureId: procedure.id,
                wearables: wearables,
                wearablesVM: wearablesVM,
                progressStore: progressStore
              )
            } label: {
              ProcedureCardView(
                title: procedure.title,
                description: procedure.description,
                stepCount: procedure.steps.count,
                duration: procedure.totalDuration,
                createdAt: procedure.createdAt,
                status: procedure.status
              )
            }
          }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.lg)
      }
    }
  }

  // MARK: - History

  @ViewBuilder
  private var historySection: some View {
    if progressStore.sessionHistory.isEmpty {
      EmptyStateView(
        icon: "clock.arrow.circlepath",
        title: "No learning history",
        message: "Start a procedure to begin tracking"
      )
    } else {
      ScrollView {
        VStack(spacing: Spacing.md) {
          ForEach(progressStore.sessionHistory) { session in
            HStack(spacing: Spacing.lg) {
              Circle()
                .fill(statusColor(session.status))
                .frame(width: 10, height: 10)

              VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(session.procedureTitle)
                  .font(.retraceCallout)
                  .fontWeight(.medium)
                  .foregroundColor(.textPrimary)
                  .lineLimit(1)

                HStack(spacing: Spacing.md) {
                  Text(statusLabel(session.status))
                    .font(.retraceCaption1)
                    .foregroundColor(statusColor(session.status))

                  Text("\(session.stepsCompleted)/\(session.totalSteps) steps")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.textSecondary)

                  Text(formatDate(session.startedAt))
                    .font(.retraceCaption1)
                    .foregroundColor(.textSecondary)
                }
              }

              Spacer()
            }
            .padding(Spacing.lg)
            .background(Color.surfaceBase)
            .cornerRadius(Radius.md)
            .overlay(
              RoundedRectangle(cornerRadius: Radius.md)
                .stroke(Color.borderSubtle, lineWidth: 1)
            )
          }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.lg)
      }
    }
  }

  // MARK: - Helpers

  private func statusColor(_ status: SessionStatus) -> Color {
    switch status {
    case .completed: return .semanticSuccess
    case .inProgress: return .appPrimary
    case .abandoned: return .textTertiary
    }
  }

  private func statusLabel(_ status: SessionStatus) -> String {
    switch status {
    case .completed: return "Completed"
    case .inProgress: return "In Progress"
    case .abandoned: return "Abandoned"
    }
  }

  private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    return formatter.string(from: date)
  }
}
