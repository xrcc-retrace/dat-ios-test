import MWDATCamera
import MWDATCore
import SwiftUI

struct CoachingSessionView: View {
  let procedure: ProcedureResponse
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var progressStore: LocalProgressStore
  let serverBaseURL: String

  @Environment(\.dismiss) private var dismiss
  @StateObject private var viewModel: CoachingSessionViewModel

  @State private var showDismissConfirmation = false

  init(
    procedure: ProcedureResponse,
    wearables: WearablesInterface,
    wearablesVM: WearablesViewModel,
    progressStore: LocalProgressStore,
    serverBaseURL: String
  ) {
    self.procedure = procedure
    self.wearables = wearables
    self.wearablesVM = wearablesVM
    self.progressStore = progressStore
    self.serverBaseURL = serverBaseURL
    self._viewModel = StateObject(wrappedValue: CoachingSessionViewModel(
      procedure: procedure,
      wearables: wearables,
      serverBaseURL: serverBaseURL
    ))
  }

  var body: some View {
    ZStack {
      Color.backgroundPrimary.edgesIgnoringSafeArea(.all)

      cameraFeedBackground

      // Top bar
      VStack {
        topBar
        Spacer()
      }

      // PiP reference overlay
      if viewModel.showPiP, let clipURL = currentStepClipURL {
        PiPReferenceView(url: clipURL)
      }

      // Bottom section
      VStack {
        Spacer()

        if viewModel.isCompleted {
          completionPanel
        } else {
          stepInstructionPanel
          stepProgressSection
          controlsBar
        }
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
      viewModel.startSession(progressStore: progressStore)
    }
  }

  // MARK: - Camera Feed Background

  @ViewBuilder
  private var cameraFeedBackground: some View {
    if let frame = viewModel.currentVideoFrame {
      GeometryReader { geo in
        Image(uiImage: frame)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: geo.size.width, height: geo.size.height)
          .clipped()
      }
      .edgesIgnoringSafeArea(.all)
      .opacity(0.6)
    } else {
      VStack(spacing: Spacing.lg) {
        Image(systemName: "eyeglasses")
          .font(.system(size: 36))
          .foregroundColor(.textTertiary)
        Text("Connect glasses to see live view")
          .font(.retraceCallout)
          .foregroundColor(.textTertiary)
      }
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
        // Gemini connection indicator
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
        // Overline
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

        // Tips
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

        // Warnings
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

  // MARK: - Controls Bar

  private var controlsBar: some View {
    HStack(spacing: 0) {
      // Mic toggle
      VStack(spacing: Spacing.xs) {
        Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
          .font(.system(size: 18))
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

      // Next step — primary action, visually dominant
      Button {
        viewModel.advanceStep(progressStore: progressStore)
      } label: {
        Image(systemName: "forward.fill")
          .font(.system(size: 18, weight: .semibold))
          .foregroundColor(Color("backgroundPrimary"))
          .frame(width: 48, height: 48)
          .background(Color.appPrimary)
          .clipShape(Circle())
      }
      .buttonStyle(ScaleButtonStyle())
      .frame(maxWidth: .infinity)

      // PiP toggle
      VStack(spacing: Spacing.xs) {
        Image(systemName: viewModel.showPiP ? "pip.fill" : "pip")
          .font(.system(size: 18))
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
