import MWDATCore
import SwiftUI

/// Intro / transport picker for Troubleshoot mode.
///
/// Mirrors the glasses-vs-iPhone pattern from `LearnerProcedureDetailView`'s
/// fresh-session CTAs so users get the same capture-source choice for
/// diagnostic sessions that they have for coaching ones.
///
/// Flow:
///   ModeSelectionView → (tap Troubleshoot) → TroubleshootIntroView
///     → (pick transport) → TroubleshootSessionView
///
/// Glasses CTA gates on DAT registration + active device (same sheets as
/// the coaching flow). iPhone CTA launches immediately. The chosen
/// transport flows through to `DiagnosticSessionViewModel`, which picks
/// the right audio-session mode (`.coaching` for HFP glasses audio,
/// `.coachingPhoneOnly` for iPhone built-in mic).
struct TroubleshootIntroView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  let serverBaseURL: String
  let onExit: () -> Void

  // Drives the fullScreenCover with the chosen transport. Using `item:`
  // (as LearnerProcedureDetailView does) instead of isPresented + separate
  // transport state avoids a SwiftUI race on stale transport values.
  @State private var presentedTransport: CaptureTransport?
  @State private var showRegistrationSheet = false
  @State private var showGlassesInactiveSheet = false
  @State private var showTransportPicker = false
  @State private var pendingTransport: CaptureTransport?

  // No handoff state lives here anymore. The diagnostic→coaching
  // transition is owned by `TroubleshootSessionContainer` (private,
  // bottom of this file) which crossfades through a brief loading
  // state inside a single fullScreenCover — no flash of the intro
  // between the two flows.

  var body: some View {
    NavigationStack {
      RetraceScreen {
        VStack(alignment: .leading, spacing: Spacing.section) {
          Spacer(minLength: Spacing.xl)

          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Fix a problem")
              .font(.retraceTitle1)
              .foregroundColor(.textPrimary)
            Text("Point your camera at the device. Gemini identifies it, finds the fix, and walks you through it.")
              .font(.retraceCallout)
              .foregroundColor(.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          TroubleshootFlowSummary()

          AccentedHeroCard(
            icon: "stethoscope",
            title: "Diagnose Live",
            subtitle: "Show the device on camera and describe what's wrong."
          ) {
            showTransportPicker = true
          }

          Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.screenPadding)
      }
      .navigationTitle("Troubleshoot")
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
    }
    .preferredColorScheme(.dark)
    // Transport picker. Routing happens in onDismiss so we don't try to
    // present a registration / inactive sheet on top of the picker
    // mid-dismissal — same pattern as RecordTabView.
    .sheet(
      isPresented: $showTransportPicker,
      onDismiss: { handlePickedTransport() }
    ) {
      CaptureTransportPickerSheet(
        title: "How do you want to diagnose?",
        subtitle: nil,
        glassesActionLabel: "Diagnose with Glasses",
        iPhoneActionLabel: "Diagnose with iPhone",
        onSelect: { transport in
          pendingTransport = transport
        }
      )
    }
    .fullScreenCover(item: $presentedTransport) { transport in
      // Single cover hosts the entire diagnostic→coaching arc. The
      // container handles the handoff transition internally with a
      // crossfade through a black loading state, so the user never
      // sees this intro view between the two flows. When the
      // container's `onExit` fires (manual exit from diagnostic OR
      // user finished/exited coaching), the cover dismisses and they
      // land back here.
      TroubleshootSessionContainer(
        wearables: wearables,
        wearablesVM: wearablesVM,
        serverBaseURL: serverBaseURL,
        transport: transport,
        onExit: {
          presentedTransport = nil
        }
      )
    }
    .sheet(isPresented: $showRegistrationSheet) {
      RegistrationPromptSheet(viewModel: wearablesVM) {
        presentedTransport = .glasses
      }
    }
    .sheet(isPresented: $showGlassesInactiveSheet) {
      GlassesInactiveSheet(iPhoneAlternativeTitle: "Troubleshoot with iPhone instead") {
        presentedTransport = .iPhone
      }
    }
  }

  // MARK: - Glasses gating

  // Routes the user's transport choice after the picker sheet finishes
  // dismissing. Mirrors RecordTabView.handlePickedTransport().
  private func handlePickedTransport() {
    guard let transport = pendingTransport else { return }
    pendingTransport = nil
    switch transport {
    case .glasses:
      launchGlasses()
    case .iPhone:
      presentedTransport = .iPhone
    }
  }

  private func launchGlasses() {
    // Three-way gate, identical to LearnerProcedureDetailView.freshCTAs.
    if wearablesVM.registrationState != .registered {
      showRegistrationSheet = true
    } else if !wearablesVM.hasActiveDevice {
      showGlassesInactiveSheet = true
    } else {
      presentedTransport = .glasses
    }
  }
}

// MARK: - Diagnostic → coaching session container

/// Single-cover host that owns the diagnostic→coaching transition.
///
/// Why this exists: SwiftUI's `fullScreenCover` is sequential — you
/// can't have two stacked at once on the same parent. Routing the
/// handoff through "dismiss diagnostic cover → present coaching
/// cover" means the parent (intro) is briefly visible between them.
/// Putting both views inside a single cover, swapped via internal
/// state, eliminates the flash entirely. The cover stays presented
/// for the whole arc; only the content inside changes.
///
/// Three internal phases:
/// - `.diagnostic` — `TroubleshootSessionView` runs the live diagnostic.
/// - `.transitioning` — black loading screen held briefly so the
///   handoff feels deliberate (not a flicker), and so the user has
///   a moment to register that the mode changed before coaching's
///   own UI arrives.
/// - `.coaching` — `CoachingSessionView` takes over. Its
///   `@Environment(\.dismiss)` dismisses the parent's cover when the
///   user exits, dropping straight back to the intro.
private struct TroubleshootSessionContainer: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  let serverBaseURL: String
  let transport: CaptureTransport
  /// Bubbled up to dismiss the parent's `presentedTransport` cover.
  /// Fired on manual exit from the diagnostic; coaching exits via
  /// its own `@Environment(\.dismiss)` which also dismisses the
  /// parent's cover (popping the entire container).
  let onExit: () -> Void

  @State private var phase: Phase = .diagnostic
  @State private var pendingHandoff: LearnerSessionStartResponse?

  private enum Phase: Equatable {
    case diagnostic
    case transitioning
    case coaching
  }

  /// Floor on the loading-screen visibility. Long enough that the
  /// transition reads as deliberate (not a flicker), short enough
  /// that the user isn't waiting on us when coaching's own UI is
  /// ready to render.
  private static let transitioningHoldNanos: UInt64 = 350_000_000

  var body: some View {
    ZStack {
      switch phase {
      case .diagnostic:
        TroubleshootSessionView(
          wearables: wearables,
          wearablesVM: wearablesVM,
          progressStore: LocalProgressStore(),
          serverBaseURL: serverBaseURL,
          transport: transport,
          onExit: handleDiagnosticExit
        )
        .transition(.opacity)

      case .transitioning:
        loadingScreen
          .transition(.opacity)

      case .coaching:
        if let handoff = pendingHandoff {
          CoachingSessionView(
            procedure: handoff.procedure,
            wearables: wearables,
            wearablesVM: wearablesVM,
            progressStore: LocalProgressStore(),
            serverBaseURL: serverBaseURL,
            transport: transport
          )
          .transition(.opacity)
        }
      }
    }
    .animation(.easeInOut(duration: 0.25), value: phase)
  }

  private var loadingScreen: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      VStack(spacing: 14) {
        ProgressView()
          .tint(.white)
          .scaleEffect(1.3)
        Text("Preparing your guide…")
          .font(.retraceCallout)
          .foregroundColor(.white.opacity(0.85))
      }
    }
  }

  private func handleDiagnosticExit(_ payload: LearnerSessionStartResponse?) {
    if let payload {
      // Handoff path. Diagnostic's Gemini session is already torn
      // down inside `executeHandoff`. Stash the payload, hold on the
      // loading screen briefly, then arrive at coaching.
      pendingHandoff = payload
      phase = .transitioning
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: Self.transitioningHoldNanos)
        phase = .coaching
      }
    } else {
      // Manual exit — bubble up to dismiss the parent's cover. The
      // diagnostic's `confirmDiagnosticExit` already called
      // `viewModel.endSession()` so there's nothing live to clean up.
      onExit()
    }
  }
}
