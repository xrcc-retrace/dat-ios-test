import AVKit
import SwiftUI

struct ProcedureDetailView: View {
  let procedureId: String
  @StateObject private var viewModel = ProcedureDetailViewModel()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ZStack {
      Color.backgroundPrimary.edgesIgnoringSafeArea(.all)

      if viewModel.isLoading && viewModel.procedure == nil {
        ProgressView()
          .scaleEffect(1.5)
          .tint(.appPrimary)
      } else if let procedure = viewModel.procedure {
        procedureContent(procedure)
      } else if let error = viewModel.errorMessage {
        VStack(spacing: Spacing.lg) {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 36))
            .foregroundColor(.appPrimary)
          Text(error)
            .font(.retraceCallout)
            .foregroundColor(.textSecondary)
            .multilineTextAlignment(.center)
        }
        .padding(Spacing.screenPadding)
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle(viewModel.procedure?.title ?? "")
    .toolbarBackground(Color.backgroundPrimary, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
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
            .foregroundColor(.textSecondary)
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

  // MARK: - Content

  @ViewBuilder
  private func procedureContent(_ procedure: ProcedureResponse) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.screenPadding) {
        // Header
        VStack(alignment: .leading, spacing: Spacing.md) {
          Text(procedure.title)
            .font(.retraceTitle2)
            .fontWeight(.bold)
            .foregroundColor(.textPrimary)

          Text(procedure.description)
            .font(.retraceCallout)
            .foregroundColor(.textSecondary)

          HStack(spacing: Spacing.md) {
            MetadataPill(icon: "clock", text: formatDuration(procedure.totalDuration))
            MetadataPill(icon: "list.number", text: "\(procedure.steps.count) steps")
            MetadataPill(icon: "calendar", text: formatDate(procedure.createdAt))
          }
        }

        // Analytics stub
        analyticsSection

        // Steps
        stepsSection(procedure)

        // Source video
        sourceVideoSection(procedure)
      }
      .padding(Spacing.screenPadding)
    }
  }

  // MARK: - Analytics

  private var analyticsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      Text("ANALYTICS")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)

      HStack(spacing: Spacing.lg) {
        StatCard(value: "\u{2014}", label: "Learners Trained")
        StatCard(value: "\u{2014}", label: "Completion Rate")
        StatCard(value: "\u{2014}", label: "Avg. Time")
      }

      Text("Available with Learner Mode")
        .font(.retraceCaption2)
        .foregroundColor(.textTertiary)
    }
  }

  // MARK: - Steps

  @ViewBuilder
  private func stepsSection(_ procedure: ProcedureResponse) -> some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      HStack {
        Text("STEPS")
          .font(.retraceOverline)
          .tracking(0.5)
          .foregroundColor(.textSecondary)
        Spacer()
        Text("\(procedure.steps.count)")
          .font(.retraceOverline)
          .foregroundColor(.textSecondary)
      }

      ForEach(procedure.steps) { step in
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            StepDetailView(
              step: step,
              isExpanded: viewModel.expandedStep == step.stepNumber,
              serverBaseURL: viewModel.serverBaseURL
            ) {
              withAnimation(.easeInOut(duration: 0.25)) {
                viewModel.toggleStep(step.stepNumber)
              }
            }

            if viewModel.expandedStep == step.stepNumber {
              NavigationLink {
                StepEditView(
                  procedureId: procedureId,
                  step: step
                ) {
                  Task { await viewModel.fetchProcedure(id: procedureId) }
                }
              } label: {
                Image(systemName: "pencil")
                  .font(.retraceSubheadline)
                  .foregroundColor(.appPrimary)
                  .padding(Spacing.md)
              }
            }
          }
        }
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

  // MARK: - Source Video

  @ViewBuilder
  private func sourceVideoSection(_ procedure: ProcedureResponse) -> some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      Text("SOURCE RECORDING")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)

      if let videoURL = URL(string: "\(viewModel.serverBaseURL)/api/uploads/\(procedure.id).mp4") {
        StepClipPlayer(url: videoURL)
      }
    }
  }

  // MARK: - Formatting

  private func formatDuration(_ seconds: Double) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
  }

  private func formatDate(_ isoString: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: isoString) {
      let display = DateFormatter()
      display.dateStyle = .medium
      return display.string(from: date)
    }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: isoString) {
      let display = DateFormatter()
      display.dateStyle = .medium
      return display.string(from: date)
    }
    return isoString
  }
}
