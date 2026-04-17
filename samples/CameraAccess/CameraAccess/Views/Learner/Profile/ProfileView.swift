import SwiftUI

struct ProfileView: View {
  @ObservedObject var wearablesVM: WearablesViewModel
  @AppStorage("geminiVoice") private var geminiVoice = "Puck"
  @AppStorage("autoAdvanceEnabled") private var autoAdvanceEnabled = true

  var body: some View {
    ZStack {
      Color.backgroundPrimary.edgesIgnoringSafeArea(.all)

      ScrollView {
        VStack(spacing: Spacing.screenPadding) {
          // Profile header
          VStack(spacing: Spacing.lg) {
            Image(systemName: "person.circle.fill")
              .font(.system(size: 64))
              .foregroundColor(.appPrimary)
              .background(
                Circle()
                  .fill(Color.accentMuted)
                  .frame(width: 72, height: 72)
              )

            Text("Technician")
              .font(.retraceFace(.semibold, size: 22))
              .foregroundColor(.textPrimary)
          }
          .padding(.vertical, Spacing.xl)

          // Device section
          settingsSection(title: "DEVICE") {
            HStack(spacing: Spacing.lg) {
              Image(systemName: "eyeglasses")
                .font(.system(size: 20))
                .foregroundColor(.appPrimary)
                .frame(width: 32)

              VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Smart Glasses")
                  .font(.retraceFace(.medium, size: 17))
                  .foregroundColor(.textPrimary)
                Text(wearablesVM.registrationState == .registered ? "Connected" : "Not connected")
                  .font(.retraceSubheadline)
                  .foregroundColor(wearablesVM.registrationState == .registered ? .semanticSuccess : .textTertiary)
              }

              Spacer()

              Circle()
                .fill(wearablesVM.registrationState == .registered ? Color.semanticSuccess : Color.textTertiary)
                .frame(width: 10, height: 10)
            }
          }

          // Server section
          settingsSection(title: "SERVER") {
            NavigationLink {
              ServerSettingsView()
            } label: {
              HStack {
                Image(systemName: "server.rack")
                  .font(.system(size: 20))
                  .foregroundColor(.appPrimary)
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
                    .foregroundColor(.appPrimary)
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
                  .foregroundColor(.appPrimary)
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
                  .tint(.appPrimary)
              }
            }
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
    .navigationBarTitleDisplayMode(.large)
    .toolbarBackground(Color.backgroundPrimary, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
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
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md)
            .stroke(Color.borderSubtle, lineWidth: 1)
        )
    }
  }
}
