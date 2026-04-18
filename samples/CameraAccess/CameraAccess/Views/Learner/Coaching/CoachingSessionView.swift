import MWDATCamera
import MWDATCore
import SwiftUI

struct CoachingSessionView: View {
  let procedure: ProcedureResponse
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var progressStore: LocalProgressStore
  let serverBaseURL: String
  let transport: CaptureTransport
  let startingStep: Int?

  @Environment(\.dismiss) private var dismiss
  @StateObject private var viewModel: CoachingSessionViewModel

  @State private var showDismissConfirmation = false

  init(
    procedure: ProcedureResponse,
    wearables: WearablesInterface,
    wearablesVM: WearablesViewModel,
    progressStore: LocalProgressStore,
    serverBaseURL: String,
    transport: CaptureTransport = .glasses,
    startingStep: Int? = nil
  ) {
    self.procedure = procedure
    self.wearables = wearables
    self.wearablesVM = wearablesVM
    self.progressStore = progressStore
    self.serverBaseURL = serverBaseURL
    self.transport = transport
    self.startingStep = startingStep
    self._viewModel = StateObject(wrappedValue: CoachingSessionViewModel(
      procedure: procedure,
      wearables: wearables,
      serverBaseURL: serverBaseURL,
      transport: transport
    ))
  }

  var body: some View {
    RetraceScreen {

      VStack(spacing: 0) {
        topBar

        if viewModel.isCompleted {
          Spacer()
          completionPanel
          Spacer()
        } else {
          activityFeed
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)

          if isGeminiError {
            reconnectBanner
          }

          stepInstructionPanel
          stepProgressSection
          controlsBar
        }
      }

      // PiP reference overlay
      if viewModel.showPiP, let clipURL = currentStepClipURL {
        PiPReferenceView(url: clipURL)
      }
    }
    .preferredColorScheme(.dark)
    .alert("End Session?", isPresented: $showDismissConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("End", role: .destructive) {
        viewModel.endSession(progressStore: progressStore)
        dismiss()
      }
    } message: {
      Text("Your progress will be saved.")
    }
    .onAppear {
      viewModel.startSession(progressStore: progressStore, startingStep: startingStep)
    }
    .onDisappear {
      viewModel.endSession(progressStore: progressStore)
    }
  }

  private var isGeminiError: Bool {
    if case .error = viewModel.geminiConnectionState { return true }
    return false
  }

  private var reconnectBanner: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.appPrimary)
      Text("Voice coaching disconnected")
        .font(.retraceCallout)
        .foregroundColor(.textPrimary)
      Spacer()
      Button {
        viewModel.retryGemini()
      } label: {
        Text("Reconnect")
          .font(.retraceCallout)
          .fontWeight(.semibold)
          .foregroundColor(.appPrimary)
      }
    }
    .padding(Spacing.md)
    .glassPanel(cornerRadius: Radius.md)
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.sm)
  }

  // MARK: - Activity Feed (tool calls + live transcript)

  private var activityFeed: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          if viewModel.activity.isEmpty {
            activityEmptyState
              .frame(maxWidth: .infinity)
              .padding(.vertical, Spacing.xl)
          } else {
            ForEach(viewModel.activity) { entry in
              ActivityRow(entry: entry)
                .id(entry.id)
            }
          }
          // Anchor so we can autoscroll to the bottom.
          Color.clear
            .frame(height: 1)
            .id("activity-bottom")
        }
        .padding(.vertical, Spacing.md)
      }
      .onChange(of: viewModel.activity.count) { _ in
        withAnimation(.easeOut(duration: 0.15)) {
          proxy.scrollTo("activity-bottom", anchor: .bottom)
        }
      }
    }
    .glassPanel(cornerRadius: Radius.xl)
  }

  private var activityEmptyState: some View {
    VStack(spacing: Spacing.sm) {
      Image(systemName: "waveform")
        .font(.system(size: 28))
        .foregroundColor(.textTertiary)
      Text("Waiting for the coach…")
        .font(.retraceCallout)
        .foregroundColor(.textTertiary)
      Text("Talk to the AI — what it hears and does will show up here.")
        .font(.retraceCaption1)
        .foregroundColor(.textTertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.md)
    }
  }

  // MARK: - Top Bar

  private var topBar: some View {
    HStack {
      Button {
        showDismissConfirmation = true
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.textPrimary)
          .frame(width: 36, height: 36)
          .glassPanel(cornerRadius: 18)
      }

      Spacer()

      HStack(spacing: Spacing.sm) {
        Circle()
          .fill(geminiStatusColor)
          .frame(width: 8, height: 8)

        Text("Step \(viewModel.currentStepIndex + 1) of \(procedure.steps.count)")
          .font(.retraceCaption1)
          .fontWeight(.semibold)
          .foregroundColor(.textPrimary)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.sm)
      .glassPanel(cornerRadius: Radius.lg)
    }
    .padding(.horizontal, Spacing.xxl)
    .padding(.top, Spacing.md)
  }

  // MARK: - Step Instruction Panel

  private var stepInstructionPanel: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let step = viewModel.currentStep {
        Text("STEP \(viewModel.currentStepIndex + 1) OF \(procedure.steps.count)")
          .font(.retraceOverline)
          .tracking(1)
          .foregroundColor(.textSecondary)

        Text(step.title)
          .font(.retraceTitle3)
          .foregroundColor(.textPrimary)

        Text(step.description)
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)

        if !step.tips.isEmpty {
          HStack(spacing: Spacing.sm) {
            ForEach(step.tips.prefix(2), id: \.self) { tip in
              Text(tip)
                .font(.retraceCaption2)
                .foregroundColor(.semanticInfo)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs)
                .background(Color.semanticInfo.opacity(0.15))
                .cornerRadius(Radius.xs)
            }
          }
        }

        if !step.warnings.isEmpty {
          HStack(spacing: Spacing.sm) {
            ForEach(step.warnings.prefix(2), id: \.self) { warning in
              Text(warning)
                .font(.retraceCaption2)
                .foregroundColor(.appPrimary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs)
                .background(Color.appPrimary.opacity(0.15))
                .cornerRadius(Radius.xs)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.xl)
    .glassPanel(cornerRadius: Radius.xl)
    .padding(.horizontal, Spacing.xl)
  }

  // MARK: - Step Progress

  private var stepProgressSection: some View {
    StepProgressBar(
      currentStep: viewModel.currentStepIndex + 1,
      totalSteps: procedure.steps.count
    )
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.md)
  }

  // MARK: - Controls Bar (mic + PiP only — step progression is AI-driven)

  private var controlsBar: some View {
    HStack(spacing: 0) {
      VStack(spacing: Spacing.xs) {
        Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
          .font(.system(size: 20))
          .foregroundColor(viewModel.isMuted ? .textTertiary : .textPrimary)

        if !viewModel.isMuted {
          SoundWaveView(
            isActive: viewModel.isAISpeaking,
            color: .appPrimary
          )
        } else {
          Text("Muted")
            .font(.system(size: 10))
            .foregroundColor(.textTertiary)
        }
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .onTapGesture {
        viewModel.toggleMute()
      }

      VStack(spacing: Spacing.xs) {
        Image(systemName: viewModel.showPiP ? "pip.fill" : "pip")
          .font(.system(size: 20))
          .foregroundColor(viewModel.showPiP ? .appPrimary : .textPrimary)
        Text("Reference")
          .font(.system(size: 10))
          .foregroundColor(.textSecondary)
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .onTapGesture {
        viewModel.showPiP.toggle()
      }
    }
    .padding(.vertical, Spacing.lg)
    .padding(.horizontal, Spacing.xl)
    .glassPanel(cornerRadius: Radius.xl)
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.md)
  }

  // MARK: - Completion Panel

  private var completionPanel: some View {
    VStack(spacing: Spacing.xl) {
      Image(systemName: "checkmark.seal.fill")
        .font(.system(size: 48))
        .foregroundColor(.semanticSuccess)

      Text("Procedure Complete")
        .font(.retraceTitle2)
        .fontWeight(.bold)
        .foregroundColor(.textPrimary)

      HStack(spacing: Spacing.xl) {
        InfoItem(label: "Steps", value: "\(procedure.steps.count)")
        InfoItem(label: "Time", value: viewModel.formattedSessionDuration)
      }

      CustomButton(
        title: "Done",
        style: .primary,
        isDisabled: false
      ) {
        dismiss()
      }
    }
    .padding(Spacing.screenPadding)
    .frame(maxWidth: .infinity)
    .glassPanel(cornerRadius: Radius.xl)
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.xl)
  }

  // MARK: - Helpers

  private var geminiStatusColor: Color {
    switch viewModel.geminiConnectionState {
    case .connected:
      return .green
    case .connecting:
      return .yellow
    case .error:
      return .red
    case .disconnected:
      return .gray
    }
  }

  private var currentStepClipURL: URL? {
    guard let step = viewModel.currentStep,
          let clipUrl = step.clipUrl else { return nil }
    return URL(string: "\(serverBaseURL)\(clipUrl)")
  }
}

// MARK: - Activity Row

private struct ActivityRow: View {
  let entry: ActivityEntry

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      icon
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.retraceOverline)
          .tracking(1)
          .foregroundColor(labelColor)
        Text(entry.text)
          .font(.retraceCallout)
          .foregroundColor(.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  @ViewBuilder
  private var icon: some View {
    switch entry.kind {
    case .toolCall:
      Image(systemName: "wand.and.stars")
        .foregroundColor(.appPrimary)
    case .assistant:
      Image(systemName: "sparkles")
        .foregroundColor(.semanticInfo)
    case .learner:
      Image(systemName: "person.fill")
        .foregroundColor(.textSecondary)
    }
  }

  private var label: String {
    switch entry.kind {
    case .toolCall(let name): return "TOOL · \(name)".uppercased()
    case .assistant: return "AI"
    case .learner: return "YOU"
    }
  }

  private var labelColor: Color {
    switch entry.kind {
    case .toolCall: return .appPrimary
    case .assistant: return .semanticInfo
    case .learner: return .textSecondary
    }
  }
}
