import SwiftUI

struct LearnerProgressView: View {
  @ObservedObject var progressStore: LocalProgressStore
  let onExit: () -> Void

  @State private var isEditing = false
  @State private var selectedIDs: Set<String> = []
  @State private var showDeleteSelectedConfirm = false
  @State private var showDeleteAllConfirm = false

  var body: some View {
    ZStack(alignment: .bottom) {
      RetraceScreen {

        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.screenPadding) {
            // Stats cards
            HStack(spacing: Spacing.lg) {
              StatCard(
                value: "\(progressStore.completedCount)",
                label: "Completed"
              )
              StatCard(
                value: "\(progressStore.totalStepsMastered)",
                label: "Total Steps"
              )
              StatCard(
                value: formatTime(progressStore.totalTimeTraining),
                label: "Time Spent"
              )
            }

            activityOverview

            sessionHistory
          }
          .padding(Spacing.screenPadding)
          .padding(.bottom, isEditing ? 80 : 0)
        }
      }

      if isEditing {
        deleteBottomBar
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: isEditing)
    .navigationTitle("Training Log")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        if isEditing {
          Button("Cancel") {
            isEditing = false
            selectedIDs.removeAll()
          }
          .foregroundColor(.textPrimary)
        } else {
          Button {
            onExit()
          } label: {
            Image(systemName: "chevron.backward")
              .foregroundColor(.textPrimary)
          }
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        if isEditing {
          Button("Done") {
            isEditing = false
            selectedIDs.removeAll()
          }
          .foregroundColor(.textPrimary)
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
              .foregroundColor(.textPrimary)
          }
        }
      }
    }
    .retraceNavBar()
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

  // MARK: - Activity Overview

  private var activityOverview: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      Text("LAST 7 DAYS")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)

      let days = progressStore.activeDays(last: 7)
      let dayLabels = recentDayLabels(count: 7)

      HStack(spacing: 0) {
        ForEach(0..<7, id: \.self) { index in
          VStack(spacing: Spacing.sm) {
            Circle()
              .fill(days[index] ? Color.textPrimary : Color.surfaceRaised)
              .frame(width: 24, height: 24)
            Text(dayLabels[index])
              .font(.system(size: 10))
              .foregroundColor(.textSecondary)
          }
          .frame(maxWidth: .infinity)
        }
      }
      .padding(Spacing.xl)
      .background(Color.surfaceBase)
      .cornerRadius(Radius.md)
    }
  }

  // MARK: - Session History

  private var sessionHistory: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      Text("RECENT ACTIVITY")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)

      if progressStore.sessionHistory.isEmpty {
        Text("No activity yet. Start a procedure to begin tracking.")
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
          .padding(.vertical, Spacing.xxl)
      } else {
        ForEach(progressStore.sessionHistory.prefix(20)) { session in
          HStack(spacing: Spacing.lg) {
            if isEditing {
              Image(systemName: selectedIDs.contains(session.id) ? "checkmark.circle.fill" : "circle")
                .foregroundColor(selectedIDs.contains(session.id) ? .textPrimary : .textTertiary)
                .font(.system(size: 20))
            }

            Image(systemName: session.status == .completed ? "checkmark.circle.fill" : "arrow.right.circle")
              .foregroundColor(session.status == .completed ? .semanticSuccess : .appPrimary)
              .font(.system(size: 20))

            VStack(alignment: .leading, spacing: Spacing.xxs) {
              Text(session.procedureTitle)
                .font(.retraceFace(.medium, size: 16))
                .foregroundColor(.textPrimary)
                .lineLimit(1)

              HStack(spacing: Spacing.md) {
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
          .cornerRadius(Radius.sm)
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
    }
  }

  // MARK: - Helpers

  private func formatTime(_ seconds: TimeInterval) -> String {
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60
    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
  }

  private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    return formatter.string(from: date)
  }

  private func recentDayLabels(count: Int) -> [String] {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE"
    let calendar = Calendar.current
    return (0..<count).reversed().map { offset in
      let date = calendar.date(byAdding: .day, value: -offset, to: Date())!
      return formatter.string(from: date)
    }
  }
}
