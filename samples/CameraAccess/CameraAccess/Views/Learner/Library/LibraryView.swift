import MWDATCore
import SwiftUI

struct LibraryView: View {
  @ObservedObject var progressStore: LocalProgressStore
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  let onExit: () -> Void
  @State private var selectedSegment = 0
  @StateObject private var viewModel = LibraryViewModel()

  @State private var isEditing = false
  @State private var selectedIDs: Set<String> = []
  @State private var showDeleteSelectedConfirm = false
  @State private var showDeleteAllConfirm = false

  var body: some View {
    ZStack(alignment: .bottom) {
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

      if selectedSegment == 1 && isEditing {
        deleteBottomBar
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: isEditing)
    .navigationTitle("My Library")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        if isEditing {
          Button("Cancel") {
            isEditing = false
            selectedIDs.removeAll()
          }
          .foregroundColor(.textSecondary)
        } else {
          Button {
            onExit()
          } label: {
            Image(systemName: "chevron.backward")
              .foregroundColor(.textSecondary)
          }
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        if selectedSegment == 1 {
          if isEditing {
            Button("Done") {
              isEditing = false
              selectedIDs.removeAll()
            }
            .foregroundColor(.appPrimary)
          } else {
            Menu {
              Button {
                isEditing = true
              } label: {
                Label("Select", systemImage: "checkmark.circle")
              }
              .disabled(progressStore.sessionHistory.isEmpty)

              Button(role: .destructive) {
                showDeleteAllConfirm = true
              } label: {
                Label("Delete All", systemImage: "trash")
              }
              .disabled(progressStore.sessionHistory.isEmpty)
            } label: {
              Image(systemName: "ellipsis.circle")
                .foregroundColor(.textSecondary)
            }
          }
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
    .onChange(of: selectedSegment) { _, _ in
      isEditing = false
      selectedIDs.removeAll()
    }
    .alert("Delete \(selectedIDs.count) entr\(selectedIDs.count == 1 ? "y" : "ies")?",
           isPresented: $showDeleteSelectedConfirm) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        progressStore.deleteSessions(ids: selectedIDs)
        selectedIDs.removeAll()
        isEditing = false
      }
    } message: {
      Text("This removes the selected training log entries from this device.")
    }
    .alert("Delete all training log entries?", isPresented: $showDeleteAllConfirm) {
      Button("Cancel", role: .cancel) {}
      Button("Delete All", role: .destructive) {
        progressStore.clearAllHistory()
        selectedIDs.removeAll()
        isEditing = false
      }
    } message: {
      Text("This permanently clears your full training log on this device. Your saved procedures stay intact.")
    }
  }

  // MARK: - Delete bottom bar

  private var deleteBottomBar: some View {
    HStack {
      Spacer()
      Button {
        showDeleteSelectedConfirm = true
      } label: {
        Text(selectedIDs.isEmpty ? "Delete" : "Delete (\(selectedIDs.count))")
          .font(.retraceCallout)
          .fontWeight(.semibold)
          .foregroundColor(.white)
          .padding(.horizontal, Spacing.xxl)
          .padding(.vertical, Spacing.lg)
          .background(selectedIDs.isEmpty ? Color.textTertiary : Color.semanticError)
          .cornerRadius(Radius.full)
      }
      .disabled(selectedIDs.isEmpty)
      Spacer()
    }
    .padding(.bottom, Spacing.xl)
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
              if isEditing {
                Image(systemName: selectedIDs.contains(session.id) ? "checkmark.circle.fill" : "circle")
                  .foregroundColor(selectedIDs.contains(session.id) ? .appPrimary : .textTertiary)
                  .font(.system(size: 20))
              }

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
            .contentShape(Rectangle())
            .onTapGesture {
              guard isEditing else { return }
              if selectedIDs.contains(session.id) {
                selectedIDs.remove(session.id)
              } else {
                selectedIDs.insert(session.id)
              }
            }
          }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.lg)
        .padding(.bottom, isEditing ? 80 : 0)
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
