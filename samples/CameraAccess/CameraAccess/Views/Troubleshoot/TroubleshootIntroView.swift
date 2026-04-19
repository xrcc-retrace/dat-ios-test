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

  var body: some View {
    RetraceScreen {
      VStack(spacing: Spacing.section) {
        topBar

        VStack(spacing: Spacing.lg) {
          Image(systemName: "stethoscope")
            .font(.system(size: 44))
            .foregroundColor(.textPrimary)
            .padding(.top, Spacing.xl)

          Text("Troubleshoot")
            .font(.retraceTitle2)
            .foregroundColor(.textPrimary)

          Text("Show the problem, describe it out loud, and I'll walk you to the fix.")
            .font(.retraceCallout)
            .foregroundColor(.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.xl)
        }

        Spacer()

        VStack(spacing: Spacing.xl) {
          ModeCard(
            icon: "eyeglasses",
            title: "Troubleshoot with Glasses",
            subtitle: "Show me through your Ray-Ban Meta glasses",
            isEnabled: true
          ) {
            launchGlasses()
          }

          ModeCard(
            icon: "iphone",
            title: "Troubleshoot with iPhone",
            subtitle: "Use your iPhone camera and mic",
            isEnabled: true
          ) {
            presentedTransport = .iPhone
          }
        }

        Spacer()
      }
      .padding(.horizontal, Spacing.screenPadding)
    }
    .preferredColorScheme(.dark)
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

  // MARK: - Top bar

  private var topBar: some View {
    HStack {
      Button {
        onExit()
      } label: {
        Image(systemName: "chevron.left")
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(.textPrimary)
          .frame(width: 36, height: 36)
          .glassPanel(cornerRadius: 18)
      }
      Spacer()
    }
    .padding(.horizontal, Spacing.xxl)
    .padding(.top, Spacing.md)
  }

  // MARK: - Glasses gating

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
