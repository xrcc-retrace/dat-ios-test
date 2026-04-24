import SwiftUI

struct ServerSettingsDetailView: View {
  var body: some View {
    RetraceScreen {
      ScrollView {
        VStack(spacing: Spacing.screenPadding) {
          ServerSettingsSection()

          privacyCard

          Spacer(minLength: 40)
        }
        .padding(Spacing.screenPadding)
      }
    }
    .navigationTitle("Server Settings")
    .navigationBarTitleDisplayMode(.inline)
    .retraceNavBar()
  }

  // MARK: - Privacy & data card

  @ViewBuilder
  private var privacyCard: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Privacy & Data")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)
        .textCase(.uppercase)

      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.md) {
          Image(systemName: "lock.shield")
            .font(.system(size: 22))
            .foregroundColor(.textPrimary)
            .frame(width: 32)
          Text("Your data stays yours")
            .font(.retraceCallout)
            .fontWeight(.semibold)
            .foregroundColor(.textPrimary)
          Spacer()
        }

        Text(
          "The Retrace server runs on your own network — auto-discovered over Bonjour. Expert videos and the procedures generated from them are stored locally on that server, never uploaded to a third party."
        )
        .font(.retraceSubheadline)
        .foregroundColor(.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

        Text(
          "Live coaching audio and video stream directly from your phone to Gemini Live over an encrypted WebSocket — they don't pass through our server at all."
        )
        .font(.retraceSubheadline)
        .foregroundColor(.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(14)
      .background(Color.surfaceRaised)
      .cornerRadius(Radius.md)
    }
    .padding(.top, Spacing.xl)
  }
}
