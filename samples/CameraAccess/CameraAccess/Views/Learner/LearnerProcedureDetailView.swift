import MWDATCore
import SwiftUI

struct LearnerProcedureDetailView: View {
  let procedureId: String
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var progressStore: LocalProgressStore

  @StateObject private var viewModel = ProcedureDetailViewModel()
  @State private var presentedCoaching: CaptureTransport?
  @State private var showRegistrationSheet = false
  @State private var showGlassesInactiveSheet = false
  @State private var isStartCoachingExpanded = false
  @State private var coachingStartingStep: Int?
  @State private var resumeTransport: CaptureTransport = .iPhone

  var body: some View {
    RetraceScreen {
      ZStack {
        content

        if showsStartCoachingDismissOverlay {
          Color.black.opacity(0.001)
            .contentShape(Rectangle())
            .onTapGesture {
              collapseStartCoachingCTA()
            }
            .transition(.opacity)
        }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("Workflow")
    .retraceNavBar()
    .task {
      await viewModel.fetchProcedure(id: procedureId)
    }
    .fullScreenCover(item: $presentedCoaching) { transport in
      if let procedure = viewModel.procedure {
        CoachingSessionView(
          procedure: procedure,
          wearables: wearables,
          wearablesVM: wearablesVM,
          progressStore: progressStore,
          serverBaseURL: viewModel.serverBaseURL,
          transport: transport,
          startingStep: coachingStartingStep
        )
      }
    }
    .onChange(of: presentedCoaching) { _, new in
      if new == nil { coachingStartingStep = nil }
    }
    .sheet(isPresented: $showRegistrationSheet) {
      RegistrationPromptSheet(viewModel: wearablesVM) {
        presentedCoaching = .glasses
      }
    }
    .sheet(isPresented: $showGlassesInactiveSheet) {
      GlassesInactiveSheet(iPhoneAlternativeTitle: "Coach with iPhone instead") {
        presentedCoaching = .iPhone
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let procedure = viewModel.procedure {
        learnerCTAInset(for: procedure)
      }
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
        metrics: learnerMetrics(for: procedure),
        readMoreContent: learnerReadMoreContent(for: procedure),
        headerActionContent: saveButton(for: procedure),
        expandedStepFooter: { _ in EmptyView() }
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

  private func learnerMetrics(for procedure: ProcedureResponse) -> [ProcedureMetricItem] {
    let full = ProcedureMetricItem.workflowSummary(
      duration: procedure.totalDuration,
      stepCount: procedure.steps.count,
      completionCount: progressStore.completedCount(for: procedure.id)
    )
    // For manual/web procedures, the totalDuration is a 30s-per-step
    // placeholder Gemini emits for API compatibility. Drop the duration
    // metric so we don't show a misleading "X minutes". Step count +
    // completion count remain meaningful and stay in the strip.
    let st = (procedure.sourceType ?? "video").lowercased()
    guard st == "video" else {
      return full.filter { $0.icon != "clock" }
    }
    return full
  }

  @ViewBuilder
  private func learnerReadMoreContent(for procedure: ProcedureResponse) -> some View {
    if let resumable = progressStore.inProgressSession(for: procedure.id) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        Divider()
          .background(Color.borderSubtle)

        resumeProgressSection(resumable)
      }
    } else {
      EmptyView()
    }
  }

  private func saveButton(for procedure: ProcedureResponse) -> some View {
    Button {
      progressStore.toggleSaved(procedure.id)
    } label: {
      HStack(spacing: Spacing.md) {
        Image(systemName: progressStore.isSaved(procedure.id) ? "bookmark.fill" : "bookmark")
          .foregroundColor(.textPrimary)
        Text(progressStore.isSaved(procedure.id) ? "Saved to Library" : "Save to Library")
          .font(.retraceFace(.medium, size: 17))
          .foregroundColor(.textPrimary)
      }
      .frame(maxWidth: .infinity)
      .frame(height: 48)
      .background(Color.surfaceBase)
      .cornerRadius(Radius.full)
    }
    .buttonStyle(ScaleButtonStyle())
  }

  @ViewBuilder
  private func learnerCTAInset(for procedure: ProcedureResponse) -> some View {
    let resumable = progressStore.inProgressSession(for: procedure.id)

    VStack(spacing: 0) {
      LinearGradient(
        colors: [Color.backgroundPrimary.opacity(0), Color.backgroundPrimary],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 20)

      Group {
        if let resumable {
          resumeCTAs(resumable)
        } else {
          freshCTAs
        }
      }
      .padding(.horizontal, Spacing.screenPadding)
      .padding(.bottom, Spacing.xl)
      .background(Color.backgroundPrimary)
    }
  }

  @ViewBuilder
  private func resumeProgressSection(_ resumable: SessionRecord) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack {
        Text("IN PROGRESS")
          .font(.retraceOverline)
          .tracking(0.5)
          .foregroundColor(.appPrimary)

        Spacer()

        Text(relativeTime(from: resumable.startedAt))
          .font(.retraceCaption1)
          .foregroundColor(.textSecondary)
      }

      StepProgressBar(
        currentStep: resumable.stepsCompleted,
        totalSteps: resumable.totalSteps
      )

      Text("Step \(resumable.stepsCompleted + 1) of \(resumable.totalSteps)")
        .font(.retraceCallout)
        .foregroundColor(.textPrimary)
    }
    .padding(Spacing.xl)
    .background(Color.surfaceBase)
    .cornerRadius(Radius.lg)
  }

  @ViewBuilder
  private var freshCTAs: some View {
    VStack(spacing: Spacing.md) {
      if isStartCoachingExpanded {
        CustomButton(
          title: "Coach with Glasses",
          icon: "eyeglasses",
          style: .primary,
          isDisabled: false
        ) {
          launchCoaching(transport: .glasses, startingStep: nil)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))

        CustomButton(
          title: "Coach with iPhone",
          icon: "iphone",
          style: .secondary,
          isDisabled: false
        ) {
          launchCoaching(transport: .iPhone, startingStep: nil)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      } else {
        CustomButton(
          title: "Start coaching",
          icon: "play.fill",
          style: .primary,
          isDisabled: false
        ) {
          withAnimation(.easeInOut(duration: 0.2)) {
            isStartCoachingExpanded = true
          }
        }
        .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: isStartCoachingExpanded)
  }

  @ViewBuilder
  private func resumeCTAs(_ resumable: SessionRecord) -> some View {
    let continueStep = resumable.stepsCompleted + 1

    VStack(spacing: Spacing.md) {
      HStack(spacing: 0) {
        transportPillOption(
          label: "Glasses",
          icon: "eyeglasses",
          value: .glasses
        )
        transportPillOption(
          label: "iPhone",
          icon: "iphone",
          value: .iPhone
        )
      }
      .padding(4)
      .background(Color.surfaceBase)
      .clipShape(Capsule())

      CustomButton(
        title: "Continue from Step \(continueStep)",
        icon: "arrow.right.circle.fill",
        style: .primary,
        isDisabled: false
      ) {
        launchCoaching(transport: resumeTransport, startingStep: continueStep)
      }

      CustomButton(
        title: "Start Over",
        icon: "arrow.counterclockwise",
        style: .secondary,
        isDisabled: false
      ) {
        progressStore.updateSession(
          id: resumable.id,
          stepsCompleted: resumable.stepsCompleted,
          status: .abandoned
        )
        launchCoaching(transport: resumeTransport, startingStep: nil)
      }
    }
  }

  @ViewBuilder
  private func transportPillOption(
    label: String,
    icon: String,
    value: CaptureTransport
  ) -> some View {
    let isSelected = resumeTransport == value

    Button {
      resumeTransport = value
    } label: {
      HStack(spacing: 6) {
        Image(systemName: icon)
        Text(label)
      }
      .font(.retraceCallout)
      .fontWeight(isSelected ? .semibold : .regular)
      .foregroundColor(isSelected ? .backgroundPrimary : .textSecondary)
      .frame(maxWidth: .infinity)
      .frame(height: 36)
      .background(isSelected ? Color.textPrimary : Color.clear)
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  private var showsStartCoachingDismissOverlay: Bool {
    guard isStartCoachingExpanded, let procedure = viewModel.procedure else { return false }
    return progressStore.inProgressSession(for: procedure.id) == nil
  }

  private func collapseStartCoachingCTA() {
    withAnimation(.easeInOut(duration: 0.2)) {
      isStartCoachingExpanded = false
    }
  }

  private func launchCoaching(transport: CaptureTransport, startingStep: Int?) {
    collapseStartCoachingCTA()
    coachingStartingStep = startingStep
    switch transport {
    case .glasses:
      // HOTFIX: see RecordTabView.handlePickedTransport.
      showGlassesInactiveSheet = true
    case .iPhone:
      presentedCoaching = .iPhone
    }
  }

  private func relativeTime(from date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return "Started " + formatter.localizedString(for: date, relativeTo: Date())
  }
}
