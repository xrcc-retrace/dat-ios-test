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
      TroubleshootSessionView(
        wearables: wearables,
        wearablesVM: wearablesVM,
        progressStore: LocalProgressStore(),
        serverBaseURL: serverBaseURL,
        transport: transport,
        onExit: {
          // Close the cover but stay on the intro — user can pick a
          // different transport, or tap the back arrow to return to
          // the mode selector.
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
