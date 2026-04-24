import MWDATCore
import SwiftUI

struct GlassesSettingsView: View {
  @ObservedObject var wearablesVM: WearablesViewModel

  var body: some View {
    RetraceScreen {
      ScrollView {
        VStack(spacing: Spacing.screenPadding) {
          GlassesSettingsSection(wearablesVM: wearablesVM)

          pairedDevicesSection

          aboutCard

          Spacer(minLength: 40)
        }
        .padding(Spacing.screenPadding)
      }
    }
    .navigationTitle("Smart Glasses")
    .navigationBarTitleDisplayMode(.inline)
    .retraceNavBar()
  }

  // MARK: - Paired devices list

  @ViewBuilder
  private var pairedDevicesSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Paired Devices")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)
        .textCase(.uppercase)

      if wearablesVM.devices.isEmpty {
        HStack(spacing: Spacing.md) {
          Image(systemName: "eyeglasses")
            .font(.system(size: 18))
            .foregroundColor(.textTertiary)
          Text("No paired devices yet.")
            .font(.retraceCallout)
            .foregroundColor(.textSecondary)
          Spacer()
        }
        .padding(14)
        .background(Color.surfaceRaised)
        .cornerRadius(Radius.md)
      } else {
        VStack(spacing: Spacing.xs) {
          ForEach(Array(wearablesVM.devices.enumerated()), id: \.offset) { _, deviceId in
            deviceRow(deviceId)
          }
        }
      }
    }
    .padding(.top, Spacing.xl)
  }

  @ViewBuilder
  private func deviceRow(_ deviceId: DeviceIdentifier) -> some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: "eyeglasses")
        .font(.system(size: 20))
        .foregroundColor(.textPrimary)
        .frame(width: 32)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(wearablesVM.displayName(for: deviceId))
          .font(.retraceCallout)
          .fontWeight(.semibold)
          .foregroundColor(.textPrimary)
        Text(String(describing: deviceId))
          .font(.system(size: 12, design: .monospaced))
          .foregroundColor(.textSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer()

      if wearablesVM.hasActiveDevice {
        HStack(spacing: Spacing.xxs) {
          Circle()
            .fill(Color.green)
            .frame(width: 8, height: 8)
          Text("Connected")
            .font(.retraceCaption1)
            .foregroundColor(.green)
        }
      }
    }
    .padding(14)
    .background(Color.surfaceRaised)
    .cornerRadius(Radius.md)
  }

  // MARK: - About card (Ray-Ban Meta + DAT SDK)

  @ViewBuilder
  private var aboutCard: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("About")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)
        .textCase(.uppercase)

      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.md) {
          Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: 22))
            .foregroundColor(.textPrimary)
            .frame(width: 32)
          Text("Powered by Ray-Ban Meta")
            .font(.retraceCallout)
            .fontWeight(.semibold)
            .foregroundColor(.textPrimary)
          Spacer()
        }

        Text(
          "Retrace streams video and audio from Meta Ray-Ban smart glasses using Meta's Wearables Device Access Toolkit (DAT SDK). No glasses? The app also works iPhone-only — pick the capture transport each session."
        )
        .font(.retraceSubheadline)
        .foregroundColor(.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

        Link(
          "Learn more about the DAT SDK",
          destination: URL(string: "https://wearables.developer.meta.com/docs/develop/")!
        )
        .font(.retraceCallout)
        .foregroundColor(.textPrimary)
      }
      .padding(14)
      .background(Color.surfaceRaised)
      .cornerRadius(Radius.md)
    }
    .padding(.top, Spacing.xl)
  }
}
