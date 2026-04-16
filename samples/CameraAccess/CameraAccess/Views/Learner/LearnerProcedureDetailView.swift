import MWDATCore
import SwiftUI

struct LearnerProcedureDetailView: View {
  let procedureId: String
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var progressStore: LocalProgressStore

  @StateObject private var viewModel = ProcedureDetailViewModel()
  @State private var showCoachingSession = false

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
    .toolbarBackground(.hidden, for: .navigationBar)
    .task {
      await viewModel.fetchProcedure(id: procedureId)
    }
    .fullScreenCover(isPresented: $showCoachingSession) {
      if let procedure = viewModel.procedure {
        CoachingSessionView(
          procedure: procedure,
          wearables: wearables,
          wearablesVM: wearablesVM,
          progressStore: progressStore,
          serverBaseURL: viewModel.serverBaseURL
        )
      }
    }
  }

  @ViewBuilder
  private func procedureContent(_ procedure: ProcedureResponse) -> some View {
    ZStack(alignment: .bottom) {
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
              MetadataPill(icon: "person.2", text: "0 completions")
            }
          }

          // Completion stats placeholder
          HStack(spacing: Spacing.lg) {
            StatCard(value: "\u{2014}", label: "Completions")
            StatCard(value: "\u{2014}", label: "Avg. Time")
          }

          // Save to library button
          Button {
            progressStore.toggleSaved(procedure.id)
          } label: {
            HStack(spacing: Spacing.md) {
              Image(systemName: progressStore.isSaved(procedure.id) ? "bookmark.fill" : "bookmark")
                .foregroundColor(.appPrimary)
              Text(progressStore.isSaved(procedure.id) ? "Saved to Library" : "Save to Library")
                .font(.retraceBody)
                .fontWeight(.medium)
                .foregroundColor(.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.surfaceBase)
            .cornerRadius(Radius.full)
            .overlay(
              RoundedRectangle(cornerRadius: Radius.full)
                .stroke(Color.borderSubtle, lineWidth: 1)
            )
          }

          // Steps preview
          stepsSection(procedure)

          // Warnings summary
          warningsSummary(procedure)

          // Tips summary
          tipsSummary(procedure)

          // Bottom spacer for pinned button
          Spacer().frame(height: 80)
        }
        .padding(Spacing.screenPadding)
      }

      // Pinned CTA
      VStack(spacing: 0) {
        LinearGradient(
          colors: [Color.backgroundPrimary.opacity(0), Color.backgroundPrimary],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(height: 20)

        CustomButton(
          title: "Start Procedure",
          style: .primary,
          isDisabled: false
        ) {
          showCoachingSession = true
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.bottom, Spacing.xl)
        .background(Color.backgroundPrimary)
      }
    }
  }

  @ViewBuilder
  private func stepsSection(_ procedure: ProcedureResponse) -> some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      Text("STEPS")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)

      ForEach(procedure.steps) { step in
        StepDetailView(
          step: step,
          isExpanded: viewModel.expandedStep == step.stepNumber,
          serverBaseURL: viewModel.serverBaseURL
        ) {
          withAnimation(.easeInOut(duration: 0.25)) {
            viewModel.toggleStep(step.stepNumber)
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

  @ViewBuilder
  private func warningsSummary(_ procedure: ProcedureResponse) -> some View {
    let allWarnings = procedure.steps.flatMap(\.warnings)
    if !allWarnings.isEmpty {
      TagSection(title: "Warnings", items: allWarnings, color: .appPrimary)
    }
  }

  @ViewBuilder
  private func tipsSummary(_ procedure: ProcedureResponse) -> some View {
    let allTips = procedure.steps.flatMap(\.tips)
    if !allTips.isEmpty {
      TagSection(title: "Tips", items: allTips, color: .semanticInfo)
    }
  }

  private func formatDuration(_ seconds: Double) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
  }
}
