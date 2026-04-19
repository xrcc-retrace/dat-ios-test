import MWDATCore
import SwiftUI

enum AppMode {
  case expert
  case learner
  case troubleshoot
}

struct ModeSelectionView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @State private var selectedMode: AppMode?

  var body: some View {
    ZStack {
      // Persistent backdrop so no edge reveals system white during transitions.
      Color.backgroundPrimary.ignoresSafeArea()

      // Base layer: the mode selector is always rendered. It stays visible
      // behind the tab view as the tab view slides in/out from the right.
      modeSelectorScreen

      // Overlay layer: the selected mode's tab view slides in from the
      // trailing edge, covering the mode selector. On exit it slides back
      // out, revealing the mode selector already in place (no blink).
      if let mode = selectedMode {
        Group {
          switch mode {
          case .expert:
            ExpertTabView(
              wearables: wearables,
              wearablesVM: wearablesVM,
              onExit: { selectedMode = nil }
            )
          case .learner:
            LearnerTabView(
              wearables: wearables,
              wearablesVM: wearablesVM,
              onExit: { selectedMode = nil }
            )
          case .troubleshoot:
            TroubleshootSessionView(
              wearables: wearables,
              wearablesVM: wearablesVM,
              progressStore: LocalProgressStore(),
              serverBaseURL: UserDefaults.standard.string(forKey: "serverBaseURL")
                ?? "http://192.168.1.100:8000",
              onExit: { selectedMode = nil }
            )
          }
        }
        .transition(.move(edge: .trailing))
        .zIndex(1)
      }
    }
    .animation(.easeInOut(duration: 0.35), value: selectedMode)
    .tint(.textPrimary)
  }

  private var modeSelectorScreen: some View {
    NavigationStack {
      RetraceScreen {

        // Subtle ambient glow
        RadialGradient(
          colors: [Color.textPrimary.opacity(0.04), .clear],
          center: UnitPoint(x: 0.5, y: 0.25),
          startRadius: 0,
          endRadius: 280
        )
        .edgesIgnoringSafeArea(.all)

        VStack(spacing: Spacing.section) {
          Spacer()

          VStack(spacing: Spacing.lg) {
            Image("RetraceLogo")
              .resizable()
              .scaledToFit()
              .frame(maxWidth: 240)

            Text("Record an expert once.\nCoach every learner forever.")
              .font(.retraceBody)
              .foregroundColor(.textSecondary)
              .multilineTextAlignment(.center)
          }

          Spacer()

          VStack(spacing: Spacing.xl) {
            ModeCard(
              icon: "video.fill",
              title: "Expert Mode",
              subtitle: "Record a procedure for learners",
              isEnabled: true
            ) {
              selectedMode = .expert
            }

            ModeCard(
              icon: "person.wave.2.fill",
              title: "Learner Mode",
              subtitle: "Learn procedures with AI coaching",
              isEnabled: true
            ) {
              selectedMode = .learner
            }

            ModeCard(
              icon: "stethoscope",
              title: "Troubleshoot",
              subtitle: "Diagnose a problem and find the fix",
              isEnabled: true
            ) {
              selectedMode = .troubleshoot
            }
          }

          Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink {
            ServerSettingsView(wearablesVM: wearablesVM)
          } label: {
            Image(systemName: "gearshape")
              .foregroundColor(.textSecondary)
          }
        }
      }
      .toolbarBackground(.hidden, for: .navigationBar)
    }
  }
}

extension AppMode: Hashable {}
