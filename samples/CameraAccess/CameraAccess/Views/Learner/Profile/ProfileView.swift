import SwiftUI

struct ProfileView: View {
  @ObservedObject var wearablesVM: WearablesViewModel
  let onExit: () -> Void
  @AppStorage(VoiceSettings.storageKey) private var geminiVoice = VoiceSettings.defaultVoice
  @AppStorage("autoAdvanceEnabled") private var autoAdvanceEnabled = true
  @AppStorage(OnboardingContainerView.completionKey) private var onboardingCompleted = true

  var body: some View {
    RetraceScreen {

      ScrollView {
        VStack(spacing: Spacing.screenPadding) {
          // Profile header
          VStack(spacing: Spacing.lg) {
            Image(systemName: "person.circle.fill")
              .font(.system(size: 64))
              .foregroundColor(.iconForeground)
              .background(
                Circle()
                  .fill(Color.iconSurface)
                  .frame(width: 72, height: 72)
              )

            Text("Technician")
              .font(.retraceFace(.semibold, size: 22))
              .foregroundColor(.textPrimary)
          }
          .padding(.vertical, Spacing.xl)

          // Mode section (top — most prominent)
          settingsSection(title: "MODE") {
            Button {
              onExit()
            } label: {
              HStack {
                Image(systemName: "rectangle.3.group")
                  .font(.system(size: 20))
                  .foregroundColor(.textPrimary)
                  .frame(width: 32)

                Text("Switch Mode")
                  .font(.retraceBody)
                  .foregroundColor(.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                  .font(.retraceSubheadline)
                  .foregroundColor(.textTertiary)
              }
            }
          }

          // Device section
          settingsSection(title: "DEVICE") {
            NavigationLink {
              GlassesSettingsView(wearablesVM: wearablesVM)
            } label: {
              let isConnected = wearablesVM.hasActiveDevice
              HStack(spacing: Spacing.lg) {
                Image(systemName: "eyeglasses")
                  .font(.system(size: 20))
                  .foregroundColor(.textPrimary)
                  .frame(width: 32)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  Text("Smart Glasses")
                    .font(.retraceFace(.medium, size: 17))
                    .foregroundColor(.textPrimary)
                  Text(isConnected ? "Connected" : "Not connected")
                    .font(.retraceSubheadline)
                    .foregroundColor(isConnected ? .semanticSuccess : .textTertiary)
                }

                Spacer()

                Circle()
                  .fill(isConnected ? Color.semanticSuccess : Color.textTertiary)
                  .frame(width: 10, height: 10)

                Image(systemName: "chevron.right")
                  .font(.retraceSubheadline)
                  .foregroundColor(.textTertiary)
              }
            }
          }

          // Server section
          settingsSection(title: "SERVER") {
            NavigationLink {
              ServerSettingsDetailView()
            } label: {
              HStack {
                Image(systemName: "server.rack")
                  .font(.system(size: 20))
                  .foregroundColor(.textPrimary)
                  .frame(width: 32)

                Text("Server Settings")
                  .font(.retraceBody)
                  .foregroundColor(.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                  .font(.retraceSubheadline)
                  .foregroundColor(.textTertiary)
              }
            }
          }

          // Preferences section
          settingsSection(title: "PREFERENCES") {
            VStack(spacing: Spacing.xl) {
              NavigationLink {
                VoiceSelectionView()
              } label: {
                HStack {
                  Image(systemName: "waveform")
                    .font(.system(size: 20))
                    .foregroundColor(.textPrimary)
                    .frame(width: 32)

                  Text("AI Voice")
                    .font(.retraceBody)
                    .foregroundColor(.textPrimary)

                  Spacer()

                  Text(geminiVoice)
                    .font(.retraceCallout)
                    .foregroundColor(.textSecondary)

                  Image(systemName: "chevron.right")
                    .font(.retraceSubheadline)
                    .foregroundColor(.textTertiary)
                }
              }

              Divider().background(Color.borderSubtle)

              HStack {
                Image(systemName: "forward.fill")
                  .font(.system(size: 20))
                  .foregroundColor(.textPrimary)
                  .frame(width: 32)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  Text("Auto-Advance Steps")
                    .font(.retraceBody)
                    .foregroundColor(.textPrimary)
                  Text("Advance when visual verification confirms completion")
                    .font(.retraceCaption1)
                    .foregroundColor(.textSecondary)
                }

                Spacer()

                Toggle("", isOn: $autoAdvanceEnabled)
                  .tint(.green)
              }
            }
          }

          // Help section — replay onboarding
          settingsSection(title: "HELP") {
            Button {
              onboardingCompleted = false
            } label: {
              HStack {
                Image(systemName: "sparkles")
                  .font(.system(size: 20))
                  .foregroundColor(.textPrimary)
                  .frame(width: 32)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  Text("Start onboarding")
                    .font(.retraceBody)
                    .foregroundColor(.textPrimary)
                  Text("Replay the intro tour from the first screen.")
                    .font(.retraceCaption1)
                    .foregroundColor(.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                  .font(.retraceSubheadline)
                  .foregroundColor(.textTertiary)
              }
            }
            .buttonStyle(.plain)
          }

          // About
          settingsSection(title: "ABOUT") {
            VStack(spacing: Spacing.xs) {
              Text("Retrace v1.0")
                .font(.retraceCallout)
                .foregroundColor(.textPrimary)
              Text("Record an expert once. Coach every learner forever.")
                .font(.retraceCaption1)
                .foregroundColor(.textSecondary)
            }
            .frame(maxWidth: .infinity)
          }
        }
        .padding(Spacing.screenPadding)
      }
    }
    .navigationTitle("Profile")
    .navigationBarTitleDisplayMode(.inline)
    .retraceNavBar()
  }

  @ViewBuilder
  private func settingsSection(title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text(title)
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)

      content()
        .padding(Spacing.xl)
        .background(Color.surfaceBase)
        .cornerRadius(Radius.md)
    }
  }
}
