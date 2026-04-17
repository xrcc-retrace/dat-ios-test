import MWDATCore
import SwiftUI

enum AppMode {
  case expert
  case learner
}

struct ModeSelectionView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @State private var selectedMode: AppMode?

  var body: some View {
    NavigationStack {
      ZStack {
        Color.backgroundPrimary.edgesIgnoringSafeArea(.all)

        // Subtle ambient glow
        RadialGradient(
          colors: [Color.appPrimary.opacity(0.06), .clear],
          center: UnitPoint(x: 0.5, y: 0.25),
          startRadius: 0,
          endRadius: 280
        )
        .edgesIgnoringSafeArea(.all)

        VStack(spacing: Spacing.section) {
          Spacer()

          VStack(spacing: Spacing.lg) {
            Text("Retrace")
              .font(.retraceDisplay)
              .foregroundColor(.textPrimary)

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
          }

          Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink {
            ServerSettingsView()
          } label: {
            Image(systemName: "gearshape")
              .foregroundColor(.textSecondary)
          }
        }
      }
      .toolbarBackground(Color.backgroundPrimary, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .navigationDestination(item: $selectedMode) { mode in
        switch mode {
        case .expert:
          ExpertTabView(wearables: wearables, wearablesVM: wearablesVM)
            .navigationBarBackButtonHidden(false)
        case .learner:
          LearnerTabView(wearables: wearables, wearablesVM: wearablesVM)
            .navigationBarBackButtonHidden(false)
        }
      }
    }
    .tint(.appPrimary)
  }
}

extension AppMode: Hashable {}

struct ModeCard: View {
  let icon: String
  let title: String
  let subtitle: String
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Spacing.xl) {
        Image(systemName: icon)
          .font(.system(size: 24))
          .foregroundColor(isEnabled ? .appPrimary : .textTertiary)
          .frame(width: 48, height: 48)
          .background(isEnabled ? Color.accentMuted : Color.surfaceRaised)
          .cornerRadius(Radius.md)

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(title)
            .font(.retraceTitle3)
            .foregroundColor(isEnabled ? .textPrimary : .textTertiary)
          Text(subtitle)
            .font(.retraceCallout)
            .foregroundColor(.textSecondary)
        }

        Spacer()

        if isEnabled {
          Image(systemName: "chevron.right")
            .font(.retraceSubheadline)
            .foregroundColor(.textTertiary)
        }
      }
      .padding(Spacing.xxl)
      .background(Color.surfaceBase)
      .cornerRadius(Radius.lg)
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg)
          .stroke(Color.borderSubtle, lineWidth: 1)
      )
    }
    .buttonStyle(ScaleButtonStyle())
    .disabled(!isEnabled)
  }
}
