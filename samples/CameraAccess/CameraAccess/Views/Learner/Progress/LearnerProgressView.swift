import SwiftUI

struct LearnerProgressView: View {
  @ObservedObject var progressStore: LocalProgressStore

  var body: some View {
    ZStack {
      Color.backgroundPrimary.edgesIgnoringSafeArea(.all)

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
              label: "Time Trained"
            )
          }

          activityOverview

          sessionHistory
        }
        .padding(Spacing.screenPadding)
      }
    }
    .navigationTitle("Training Log")
    .navigationBarTitleDisplayMode(.large)
    .toolbarBackground(Color.backgroundPrimary, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
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
              .fill(days[index] ? Color.appPrimary : Color.surfaceRaised)
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
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md)
          .stroke(Color.borderSubtle, lineWidth: 1)
      )
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
            Image(systemName: session.status == .completed ? "checkmark.circle.fill" : "arrow.right.circle")
              .foregroundColor(session.status == .completed ? .semanticSuccess : .appPrimary)
              .font(.system(size: 20))

            VStack(alignment: .leading, spacing: Spacing.xxs) {
              Text(session.procedureTitle)
                .font(.retraceCallout)
                .fontWeight(.medium)
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
          .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
              .stroke(Color.borderSubtle, lineWidth: 1)
            )
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
