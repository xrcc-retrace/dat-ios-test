import MWDATCore
import SwiftUI

struct DiscoverView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var progressStore: LocalProgressStore
  let onExit: () -> Void
  @StateObject private var viewModel = DiscoverViewModel()
  @State private var showSearch = false
  // Swipe-to-dismiss offset for the resume card. Negative only (leftward).
  @State private var resumeDragOffset: CGFloat = 0
  // Direction of the procedure-list slide animation when the chip strip
  // changes. Forward (true) means the new chip is to the right of the
  // previous one, so the new list slides in from the trailing edge.
  @State private var slideForward: Bool = true

  var body: some View {
    RetraceScreen {

      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.xxl) {
          searchBar

          if let session = progressStore.anyInProgressSession {
            swipeableResumeCard(session)
          }

          categoryChips

          animatedContent
            // Re-mount whenever the chip changes so SwiftUI runs the
            // transition. Search-query changes mutate the same list in
            // place (no re-mount, no animation) which is what we want.
            .id(viewModel.selectedCategory)
            .transition(.asymmetric(
              insertion: .move(edge: slideForward ? .trailing : .leading)
                .combined(with: .opacity),
              removal: .move(edge: slideForward ? .leading : .trailing)
                .combined(with: .opacity)
            ))
        }
        .padding(.bottom, Spacing.screenPadding)
        // Driving the animation off `selectedCategory` keeps search-typing
        // (which mutates `filteredProcedures` without changing identity)
        // animation-free, while chip taps trigger the slide.
        .animation(.smooth(duration: 0.28), value: viewModel.selectedCategory)
      }
      // Keep the slide visually contained — without this the off-screen
      // copy of the list briefly draws outside the ScrollView bounds.
      .clipped()
    }
    .navigationTitle("Procedures")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          onExit()
        } label: {
          Image(systemName: "chevron.backward")
            .foregroundColor(.textPrimary)
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

  // MARK: - Swipeable resume card wrapper

  @ViewBuilder
  private func swipeableResumeCard(_ session: SessionRecord) -> some View {
    ZStack {
      // Red trash reveal — static layer behind the sliding card. Respects the
      // card's padding so the red panel inherits the same gutter.
      HStack {
        Spacer()
        Image(systemName: "trash.fill")
          .font(.system(size: 22, weight: .semibold))
          .foregroundColor(.white)
          .padding(.trailing, Spacing.xxl)
      }
      .frame(maxWidth: .infinity)
      .frame(minHeight: 120)
      .background(Color.red)
      .cornerRadius(Radius.lg)
      .padding(.horizontal, Spacing.screenPadding)

      NavigationLink {
        LearnerProcedureDetailView(
          procedureId: session.procedureId,
          wearables: wearables,
          wearablesVM: wearablesVM,
          progressStore: progressStore
        )
      } label: {
        resumeCard(session)
      }
      .buttonStyle(.plain)
      .offset(x: min(0, resumeDragOffset))
      // simultaneousGesture so a short tap still activates the NavigationLink;
      // a leftward drag beyond 20pt is intercepted and abandons locally.
      .simultaneousGesture(
        DragGesture(minimumDistance: 20)
          .onChanged { value in
            if value.translation.width < 0 {
              resumeDragOffset = value.translation.width
            }
          }
          .onEnded { value in
            if value.translation.width < -120 {
              withAnimation(.easeInOut(duration: 0.22)) {
                resumeDragOffset = -500
              }
              // Defer the model mutation until the card finishes sliding;
              // otherwise the anyInProgressSession == nil re-render yanks
              // the card out mid-animation.
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                progressStore.updateSession(
                  id: session.id,
                  stepsCompleted: session.stepsCompleted,
                  status: .abandoned
                )
                resumeDragOffset = 0
              }
            } else {
              withAnimation(.spring()) {
                resumeDragOffset = 0
              }
            }
          }
      )
    }
  }

  // MARK: - Resume Card

  private func resumeCard(_ session: SessionRecord) -> some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      HStack {
        Text("Resume Session")
          .font(.retraceFace(.semibold, size: 13))
          .foregroundColor(.textPrimary)
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
            .fill(Color.textPrimary)
            .frame(width: 3)
            .padding(.vertical, Spacing.md)
          Spacer()
        }
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
            selectCategory(category)
          }
        }
      }
      .padding(.horizontal, Spacing.screenPadding)
    }
  }

  /// Compute slide direction from the chip strip ordering, then commit
  /// the new category. The matching `.animation(value:)` on the content
  /// wrapper picks it up.
  private func selectCategory(_ category: String) {
    guard category != viewModel.selectedCategory else { return }
    let oldIndex = viewModel.categories.firstIndex(of: viewModel.selectedCategory) ?? 0
    let newIndex = viewModel.categories.firstIndex(of: category) ?? 0
    slideForward = newIndex >= oldIndex
    viewModel.selectedCategory = category
  }

  // MARK: - Animated content

  /// The slot that animates between loading / empty / list states.
  /// Wrapped in a Group so the `.id(selectedCategory)` modifier outside
  /// can re-mount the whole subtree on chip changes.
  @ViewBuilder
  private var animatedContent: some View {
    if viewModel.isLoading && viewModel.procedures.isEmpty {
      HStack {
        Spacer()
        ProgressView()
          .tint(.textPrimary)
        Spacer()
      }
      .padding(.top, Spacing.jumbo)
    } else if viewModel.filteredProcedures.isEmpty {
      emptyState
    } else {
      procedureList
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
            status: procedure.status,
            iconSymbol: procedure.iconSymbol,
            iconEmoji: procedure.iconEmoji
          )
        }
      }
    }
    .padding(.horizontal, Spacing.screenPadding)
  }
}
