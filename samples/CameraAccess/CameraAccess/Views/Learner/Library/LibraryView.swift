import MWDATCore
import SwiftUI

struct LibraryView: View {
  @ObservedObject var progressStore: LocalProgressStore
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @State private var selectedSegment = 0
  @StateObject private var api = ProcedureAPIService()
  @State private var savedProcedures: [ProcedureResponse] = []
  @State private var isLoading = false

  var body: some View {
    ZStack {
      Color.backgroundPrimary.edgesIgnoringSafeArea(.all)

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
    }
    .navigationTitle("My Library")
    .navigationBarTitleDisplayMode(.large)
    .toolbarBackground(Color.backgroundPrimary, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .task {
      await loadSavedProcedures()
    }
    .onChange(of: progressStore.savedProcedureIDs) { _, _ in
      Task { await loadSavedProcedures() }
    }
  }

  // MARK: - Saved

  @ViewBuilder
  private var savedSection: some View {
    if isLoading {
      Spacer()
      ProgressView().tint(.appPrimary)
      Spacer()
    } else if savedProcedures.isEmpty {
      Spacer()
      VStack(spacing: Spacing.lg) {
        Image(systemName: "bookmark.slash")
          .font(.system(size: 36))
          .foregroundColor(.textTertiary)
        Text("No saved procedures")
          .font(.retraceHeadline)
          .foregroundColor(.textPrimary)
        Text("Discover procedures and save them here")
          .font(.retraceSubheadline)
          .foregroundColor(.textSecondary)
      }
      Spacer()
    } else {
      ScrollView {
        VStack(spacing: Spacing.lg) {
          ForEach(savedProcedures) { procedure in
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
      Spacer()
      VStack(spacing: Spacing.lg) {
        Image(systemName: "clock.arrow.circlepath")
          .font(.system(size: 36))
          .foregroundColor(.textTertiary)
        Text("No learning history")
          .font(.retraceHeadline)
          .foregroundColor(.textPrimary)
        Text("Start a procedure to begin tracking")
          .font(.retraceSubheadline)
          .foregroundColor(.textSecondary)
      }
      Spacer()
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
                  .font(.retraceFace(.medium, size: 16))
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

  private func loadSavedProcedures() async {
    isLoading = true
    var results: [ProcedureResponse] = []
    for id in progressStore.savedProcedureIDs {
      if let procedure = try? await api.fetchProcedure(id: id) {
        results.append(procedure)
      }
    }
    savedProcedures = results
    isLoading = false
  }

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
