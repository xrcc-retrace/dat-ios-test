import MWDATCore
import SwiftUI

struct DiscoverView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var progressStore: LocalProgressStore
  let onExit: () -> Void
  @StateObject private var viewModel = DiscoverViewModel()
  @State private var showSearch = false

  var body: some View {
    RetraceScreen {

      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.xxl) {
          searchBar

          if let session = progressStore.anyInProgressSession {
            resumeCard(session)
          }

          categoryChips

          if viewModel.isLoading && viewModel.procedures.isEmpty {
            HStack {
              Spacer()
              ProgressView()
                .tint(.appPrimary)
              Spacer()
            }
            .padding(.top, Spacing.jumbo)
          } else if viewModel.filteredProcedures.isEmpty {
            emptyState
          } else {
            procedureList
          }
        }
        .padding(.bottom, Spacing.screenPadding)
      }
    }
    .navigationTitle("Procedures")
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
        HStack(spacing: Spacing.lg) {
          Circle()
            .fill(wearablesVM.registrationState == .registered ? Color.semanticSuccess : Color.textTertiary)
            .frame(width: 8, height: 8)
        }
      }
    }
    .retraceNavBar()
    .refreshable {
      await viewModel.fetchProcedures()
    }
    .task {
      await viewModel.fetchProcedures()
    }
  }

  // MARK: - Search Bar

  private var searchBar: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: "magnifyingglass")
        .foregroundColor(.textTertiary)
      TextField("Search by device, task, or error code...", text: $viewModel.searchQuery)
        .font(.retraceBody)
        .foregroundColor(.textPrimary)
    }
    .padding(Spacing.lg)
    .background(Color.surfaceRaised)
    .cornerRadius(Radius.md)
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
    .padding(.horizontal, Spacing.screenPadding)
  }

  // MARK: - Resume Card

  private func resumeCard(_ session: SessionRecord) -> some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      HStack {
        Text("Resume Session")
          .font(.retraceSubheadline)
          .fontWeight(.semibold)
          .foregroundColor(.appPrimary)
        Spacer()
      }

      Text(session.procedureTitle)
        .font(.retraceHeadline)
        .foregroundColor(.textPrimary)

      StepProgressBar(currentStep: session.stepsCompleted, totalSteps: session.totalSteps)

      Text("\(session.stepsCompleted) of \(session.totalSteps) steps completed")
        .font(.retraceCaption1)
        .foregroundColor(.textSecondary)
    }
    .padding(Spacing.xl)
    .background(Color.surfaceBase)
    .cornerRadius(Radius.lg)
    .overlay(
      ZStack {
        // Left accent edge
        HStack {
          RoundedRectangle(cornerRadius: 2)
            .fill(Color.appPrimary)
            .frame(width: 3)
            .padding(.vertical, Spacing.md)
          Spacer()
        }
        // Border
        RoundedRectangle(cornerRadius: Radius.lg)
          .stroke(Color.appPrimary.opacity(0.2), lineWidth: 1)
      }
    )
    .padding(.horizontal, Spacing.screenPadding)
  }

  // MARK: - Category Chips

  private var categoryChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.md) {
        ForEach(viewModel.categories, id: \.self) { category in
          CategoryChip(
            title: category,
            isSelected: viewModel.selectedCategory == category
          ) {
            viewModel.selectedCategory = category
          }
        }
      }
      .padding(.horizontal, Spacing.screenPadding)
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    EmptyStateView(
      icon: "doc.text.magnifyingglass",
      title: "No procedures found",
      message: "Try a different search or category"
    )
    .padding(.top, Spacing.jumbo)
  }

  // MARK: - Procedure List

  private var procedureList: some View {
    VStack(spacing: Spacing.lg) {
      ForEach(viewModel.filteredProcedures) { procedure in
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
            stepCount: procedure.stepCount ?? 0,
            duration: procedure.totalDuration,
            createdAt: procedure.createdAt,
            status: procedure.status
          )
        }
      }
    }
    .padding(.horizontal, Spacing.screenPadding)
  }
}
