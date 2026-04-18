import MWDATCore
import SwiftUI

struct LearnerProcedureDetailView: View {
  let procedureId: String
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var progressStore: LocalProgressStore

  @StateObject private var viewModel = ProcedureDetailViewModel()
  // Single source of truth for "which transport is the coaching cover
  // presenting with." Using `item:` rather than `isPresented + separate
  // transport` avoids a SwiftUI state-race where the cover could evaluate
  // its content against a stale transport value.
  @State private var presentedCoaching: CaptureTransport?
  @State private var showRegistrationSheet = false
  @State private var showGlassesInactiveSheet = false
  // When the learner taps "Continue" on a resumable session this is set to
  // (stepsCompleted + 1); nil means "fresh session from step 1."
  @State private var coachingStartingStep: Int?
  // Transport selection for the resume flow's pill toggle. Only consulted
  // when a resumable session is present; otherwise the old two-button CTAs
  // set `presentedCoaching` directly.
  @State private var resumeTransport: CaptureTransport = .iPhone

  var body: some View {
    RetraceScreen {

      if viewModel.isLoading && viewModel.procedure == nil {
        ProgressView()
          .scaleEffect(1.5)
          .tint(.textPrimary)
      } else if let procedure = viewModel.procedure {
        procedureContent(procedure)
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
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle(viewModel.procedure?.title ?? "")
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
      // Once the cover dismisses, drop the resume anchor so the next launch
      // from the fresh-flow CTAs starts at step 1 unless explicitly resumed.
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
  }

  @ViewBuilder
  private func procedureContent(_ procedure: ProcedureResponse) -> some View {
    let resumable = progressStore.inProgressSession(for: procedure.id)

    ZStack(alignment: .bottom) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.screenPadding) {
          // Header
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text(procedure.title)
              .font(.retraceTitle2)
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

          if let resumable {
            resumeProgressSection(resumable)
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

      // Pinned CTAs — resumable procedures swap in the Continue / Start Over
      // pair with a transport pill; fresh procedures keep the two-button
      // glasses-vs-iPhone layout.
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
  }

  // MARK: - Resume progress section

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

  // MARK: - Fresh CTAs (no in-progress session)

  @ViewBuilder
  private var freshCTAs: some View {
    VStack(spacing: Spacing.md) {
      CustomButton(
        title: "Coach with Glasses",
        icon: "eyeglasses",
        style: .primary,
        isDisabled: false
      ) {
        // Three-way gate:
        //   - Not registered  → Meta AI pairing sheet
        //   - Registered but glasses not awake / in range → inactive prompt
        //   - Registered + active → start coaching
        if wearablesVM.registrationState != .registered {
          showRegistrationSheet = true
        } else if !wearablesVM.hasActiveDevice {
          showGlassesInactiveSheet = true
        } else {
          coachingStartingStep = nil
          presentedCoaching = .glasses
        }
      }

      CustomButton(
        title: "Coach with iPhone",
        icon: "iphone",
        style: .secondary,
        isDisabled: false
      ) {
        coachingStartingStep = nil
        presentedCoaching = .iPhone
      }
    }
  }

  // MARK: - Resume CTAs (in-progress session present)

  @ViewBuilder
  private func resumeCTAs(_ resumable: SessionRecord) -> some View {
    let continueStep = resumable.stepsCompleted + 1

    VStack(spacing: Spacing.md) {
      // Transport pill — single tap changes the launch path.
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

  private func launchCoaching(transport: CaptureTransport, startingStep: Int?) {
    coachingStartingStep = startingStep
    switch transport {
    case .glasses:
      if wearablesVM.registrationState != .registered {
        showRegistrationSheet = true
      } else if !wearablesVM.hasActiveDevice {
        showGlassesInactiveSheet = true
      } else {
        presentedCoaching = .glasses
      }
    case .iPhone:
      presentedCoaching = .iPhone
    }
  }

  private func relativeTime(from date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return "Started " + formatter.localizedString(for: date, relativeTo: Date())
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
