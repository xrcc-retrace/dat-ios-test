import MWDATCore
import SwiftUI

/// The Troubleshoot mode voice session. Voice-only for v1 (no camera, no
/// PiP, no step instruction panel). Peer to CoachingSessionView — fresh
/// layout, deliberate scope reduction.
struct TroubleshootSessionView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var progressStore: LocalProgressStore
  let serverBaseURL: String
  let transport: CaptureTransport
  let onExit: () -> Void

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var appOrientationController: AppOrientationController
  @StateObject private var viewModel: DiagnosticSessionViewModel

  @State private var showDismissConfirmation = false
  @State private var activeHandoff: LearnerSessionStartResponse?
  // Drawer state for the iPhone camera-first layout. Ignored on glasses
  // transport (which keeps the existing vertical stack).
  @State private var drawerExpanded = true
  // Active lens page inside the Ray-Ban emulator. Troubleshoot ships with
  // zero pages today; the designer fills them in incrementally.
  @State private var troubleshootPageIndex: Int = 0
  // Portrait is the app default; the real value is overwritten in
  // `.onAppear` from `resolveInterfaceOrientation()` so the session
  // preserves whatever orientation the phone is already in. Mirrors
  // Coaching's orientation flow.
  @State private var currentInterfaceOrientation: UIInterfaceOrientation = .portrait
  // Global debug surface — drives the lens boundary outline and the
  // hand-tracking landmark overlay. Set in Server Settings → Debug.
  @AppStorage("debugMode") private var debugMode: Bool = false
  @AppStorage("hudAdditiveBlend") private var hudAdditiveBlend: Bool = false

  init(
    wearables: WearablesInterface,
    wearablesVM: WearablesViewModel,
    progressStore: LocalProgressStore,
    serverBaseURL: String,
    transport: CaptureTransport,
    onExit: @escaping () -> Void
  ) {
    self.wearables = wearables
    self.wearablesVM = wearablesVM
    self.progressStore = progressStore
    self.serverBaseURL = serverBaseURL
    self.transport = transport
    self.onExit = onExit
    self._viewModel = StateObject(wrappedValue: DiagnosticSessionViewModel(
      wearables: wearables,
      serverBaseURL: serverBaseURL,
      transport: transport
    ))
  }

  var body: some View {
    ZStack {
      if transport == .iPhone {
        IPhoneCoachingLayout(
          viewModel: viewModel,
          drawerExpanded: $drawerExpanded,
          showDrawer: currentInterfaceOrientation.isPortrait,
          hud: {
            // Lens drives the five-step Troubleshoot flow. Exactly one page
            // is alive at a time; the page is selected from VM state. The
            // confirmation overlay layers on top via the recede+arrive
            // pattern when `pendingConfirmation == true`.
            //
            // Overlay sits *inside* the emulator's page closure (mirrors
            // ExpertNarrationTipPage's ZStack pattern, lines 56-85) so
            // both the page and the overlay are children of the emulator
            // and inherit its `HUDHoverCoordinator` environmentObject.
            // Rendering the overlay as a sibling of the emulator (the
            // older shape) leaves it without the env and crashes on first
            // hover read.
            RayBanHUDEmulator(
              pageCount: 1,
              pageIndex: $troubleshootPageIndex,
              showBoundary: debugMode,
              additiveBlend: hudAdditiveBlend,
              // Lens double-tap → focus-engine `.dismiss` → topmost
              // page handler routes to the end-diagnostic alert.
              // Mirrors Coaching's exit pattern, and gives touch
              // parity with the MediaPipe double-pinch back gesture
              // (which still also fires `viewModel.onBackGesture`
              // legacy callback below).
              enableDismissGesture: true
            ) { _ in
              ZStack {
                troubleshootCurrentPage
                  // Recede the page so the overlay reads as foreground.
                  // Combined with the overlay's heavier weight, foreground
                  // and background separate cleanly.
                  .scaleEffect(viewModel.pendingConfirmation ? 0.92 : 1.0)
                  .opacity(viewModel.pendingConfirmation ? 0.32 : 1.0)
                  .blur(radius: viewModel.pendingConfirmation ? 6 : 0)
                  .allowsHitTesting(!viewModel.pendingConfirmation)

                if viewModel.pendingConfirmation, let product = viewModel.identifiedProduct {
                  TroubleshootConfirmOverlay(
                    product: product,
                    onConfirm: { viewModel.confirmIdentification() },
                    onReject: { viewModel.requestReIdentify() }
                  )
                  .transition(.scale(scale: 0.88).combined(with: .opacity))
                }
              }
              .animation(
                .spring(response: 0.32, dampingFraction: 0.85),
                value: viewModel.pendingConfirmation
              )
              .animation(
                .spring(response: 0.32, dampingFraction: 0.85),
                value: troubleshootPageKind
              )
            }
          }
        ) {
          stackedBody
        }
      } else {
        RetraceScreen {
          stackedBody
        }
      }

      // Hand-tracking dev overlay — landmark dots, pinch-drag cross, event
      // log. Sits above everything but allows hit-testing through. Reads
      // from the single shared `HandGestureService` regardless of mode.
      if debugMode {
        HandGestureDebugStack(provider: HandGestureService.shared)
      }
    }
    .preferredColorScheme(.dark)
    .alert("End diagnostic?", isPresented: $showDismissConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("End", role: .destructive) {
        viewModel.endSession()
        dismiss()
        onExit()
      }
    } message: {
      Text("Your diagnostic conversation will end.")
    }
    .onAppear {
      // Double index-finger pinch ("back" gesture) → end-diagnostic
      // confirmation, same destination as the top-bar close button.
      viewModel.onBackGesture = {
        showDismissConfirmation = true
      }
      Task { await viewModel.startSession() }
      if transport == .iPhone {
        // Match Coaching's orientation flow — broaden the allowed mask so
        // SwiftUI chrome can follow the phone into landscape, seed the
        // preview from the scene's actual interface orientation, and let
        // the observer below forward future rotations into the camera.
        appOrientationController.setAllowed([.portrait, .landscapeLeft, .landscapeRight])
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        let resolved = resolveInterfaceOrientation()
        currentInterfaceOrientation = resolved
        viewModel.setPreviewInterfaceOrientation(resolved)
      }
    }
    .onDisappear {
      viewModel.endSession()
      if transport == .iPhone {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        appOrientationController.unlock()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      guard transport == .iPhone else { return }
      let resolved = resolveInterfaceOrientation()
      currentInterfaceOrientation = resolved
      viewModel.setPreviewInterfaceOrientation(resolved)
    }
    .fullScreenCover(item: $activeHandoff) { handoff in
      // Handoff into a learner coaching session keeps the same transport
      // the user picked for the diagnostic — picking glasses here was a
      // deliberate choice, so honor it on the learner side too.
      CoachingSessionView(
        procedure: handoff.procedure,
        wearables: wearables,
        wearablesVM: wearablesVM,
        progressStore: progressStore,
        serverBaseURL: serverBaseURL,
        transport: transport
      )
    }
    .sheet(isPresented: $viewModel.showManualUploadSheet) {
      ManualUploadSheet(
        isPresented: $viewModel.showManualUploadSheet,
        onUpload: { url in
          await viewModel.submitManualUpload(pdfURL: url)
        }
      )
      .presentationDetents([.medium, .large])
    }
  }

  // MARK: - Stacked Body (shared by glasses transport directly and by the
  // iPhone drawer)

  @ViewBuilder
  private var stackedBody: some View {
    VStack(spacing: 0) {
      topBar

      activityFeed
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.md)

      if let resolution = viewModel.resolution {
        DiagnosticResolutionPanel(
          resolution: resolution,
          isHandoffInFlight: viewModel.handoffInFlight,
          handoffError: viewModel.handoffError,
          onStartProcedure: { procedureId in
            Task { await startHandoff(procedureId: procedureId) }
          },
          onRetry: { retryDiagnostic() }
        )
      }

      phaseSection
      controlsBar
    }
  }

  // MARK: - Sections

  private var topBar: some View {
    HStack {
      Button { showDismissConfirmation = true } label: {
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.textPrimary)
          .frame(width: 36, height: 36)
          .glassPanel(cornerRadius: 18)
      }

      Spacer()

      HStack(spacing: Spacing.sm) {
        Circle()
          .fill(phaseDotColor)
          .frame(width: 8, height: 8)
        Text(topBarLabel)
          .font(.retraceFace(.semibold, size: 12))
          .foregroundColor(.textPrimary)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.sm)
      .glassPanel(cornerRadius: Radius.lg)
    }
    .padding(.horizontal, Spacing.xxl)
    .padding(.top, Spacing.md)
  }

  private var activityFeed: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          if let product = viewModel.identifiedProduct {
            productChip(product)
          }

          if viewModel.activity.isEmpty {
            activityEmptyState
              .frame(maxWidth: .infinity)
              .padding(.vertical, Spacing.xl)
          } else {
            ForEach(viewModel.activity) { entry in
              DiagnosticActivityRow(entry: entry).id(entry.id)
            }
          }

          Color.clear.frame(height: 1).id("activity-bottom")
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
      Image(systemName: "stethoscope")
        .font(.system(size: 28))
        .foregroundColor(.textTertiary)
      Text("Tell me what's wrong.")
        .font(.retraceCallout)
        .foregroundColor(.textTertiary)
      Text("Describe the product and the problem. I'll walk you through it from there.")
        .font(.retraceCaption1)
        .foregroundColor(.textTertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.md)
    }
  }

  private func productChip(_ product: IdentifiedProduct) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundColor(.semanticInfo)
      VStack(alignment: .leading, spacing: 2) {
        Text(product.productName)
          .font(.retraceCallout)
          .foregroundColor(.textPrimary)
        if !product.confidence.isEmpty {
          Text("\(product.confidence) confidence")
            .font(.retraceCaption2)
            .foregroundColor(.textTertiary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(Spacing.md)
    .glassPanel(cornerRadius: Radius.md)
  }

  private var phaseSection: some View {
    DiagnosticPhaseBar(phase: viewModel.phase)
      .padding(.horizontal, Spacing.xl)
      .padding(.vertical, Spacing.md)
  }

  private var controlsBar: some View {
    HStack(spacing: 0) {
      VStack(spacing: Spacing.xs) {
        Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
          .font(.system(size: 20))
          .foregroundColor(viewModel.isMuted ? .textTertiary : .textPrimary)

        if !viewModel.isMuted {
          RetraceAudioMeter(
            aiPeak: viewModel.aiOutputPeak,
            userPeak: viewModel.userInputPeak,
            tint: .textPrimary,
            intensity: .standard
          )
        } else {
          Text("Muted")
            .font(.system(size: 10))
            .foregroundColor(.textTertiary)
        }
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .onTapGesture { viewModel.toggleMute() }
    }
    .padding(.vertical, Spacing.lg)
    .padding(.horizontal, Spacing.xl)
    .glassPanel(cornerRadius: Radius.xl)
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.md)
  }

  // MARK: - Lens page selector

  /// Picks which Troubleshoot lens page to render based on phase + resolution.
  /// Page transitions use the asymmetric inline transition from the design
  /// system, applied at the parent ZStack via `.animation(...)` on the
  /// transition trigger key.
  @ViewBuilder
  private var troubleshootCurrentPage: some View {
    let dismissCallback: () -> Void = { showDismissConfirmation = true }
    Group {
      switch troubleshootPageKind {
      case .identify:
        TroubleshootIdentifyPage(viewModel: viewModel, onDismiss: dismissCallback)
      case .diagnose:
        TroubleshootDiagnosePage(viewModel: viewModel, onDismiss: dismissCallback)
      case .searching:
        TroubleshootSearchingPage(viewModel: viewModel, onDismiss: dismissCallback)
      case .resolved:
        TroubleshootResolvedPage(
          viewModel: viewModel,
          onStart: { procedureId in
            Task { await startHandoff(procedureId: procedureId) }
          },
          onDismiss: dismissCallback
        )
      case .noSolution:
        TroubleshootNoSolutionPage(viewModel: viewModel, onDismiss: dismissCallback)
      }
    }
    .transition(.asymmetric(
      insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)),
      removal: .opacity
    ))
  }

  private var troubleshootPageKind: TroubleshootPageKind {
    if viewModel.resolution == .noMatch { return .noSolution }
    switch viewModel.resolution {
    case .matchedProcedure, .generatedSOP:
      return .resolved
    case .none, .noMatch:
      break
    }
    switch viewModel.phase {
    case .discovering: return .identify
    case .diagnosing:  return .diagnose
    case .resolving:   return .searching
    case .resolved:    return .identify // resolution already handled above
    }
  }

  // MARK: - Helpers

  private var topBarLabel: String {
    switch viewModel.phase {
    case .discovering, .diagnosing: return "DIAGNOSING"
    case .resolving:                return "RESOLUTION"
    case .resolved:                 return "LIVE"
    }
  }

  private var phaseDotColor: Color {
    switch viewModel.geminiConnectionState {
    case .connected: return .appPrimary
    case .connecting: return .semanticInfo
    case .error: return .appPrimary
    case .disconnected: return .textTertiary
    }
  }

  private func resolveInterfaceOrientation() -> UIInterfaceOrientation {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first(where: { $0.activationState == .foregroundActive })
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    return scene?.interfaceOrientation ?? .portrait
  }

  private func startHandoff(procedureId: String) async {
    if let payload = await viewModel.executeHandoff(procedureId: procedureId, autoAdvance: true) {
      activeHandoff = payload
    }
  }

  private func retryDiagnostic() {
    viewModel.endSession()
    Task { await viewModel.startSession() }
  }
}

// MARK: - Activity row (diagnostic variant — labels differ from learner)

private struct DiagnosticActivityRow: View {
  let entry: ActivityEntry

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      icon.frame(width: 22)
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
    case .toolCall: Image(systemName: "wand.and.stars").foregroundColor(.textPrimary)
    case .assistant: Image(systemName: "sparkles").foregroundColor(.semanticInfo)
    case .learner: Image(systemName: "person.fill").foregroundColor(.textSecondary)
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
    case .toolCall: return .textPrimary
    case .assistant: return .semanticInfo
    case .learner: return .textSecondary
    }
  }
}

// Make LearnerSessionStartResponse Identifiable so it can drive
// fullScreenCover(item:).
extension LearnerSessionStartResponse: Identifiable {
  public var id: String { sessionId }
}

/// Identifies which Troubleshoot lens page is alive. Owned by
/// `TroubleshootSessionView`; computed from VM state via
/// `troubleshootPageKind`.
enum TroubleshootPageKind: Hashable {
  case identify
  case diagnose
  case searching
  case resolved
  case noSolution
}
