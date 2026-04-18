import SwiftUI
import MWDATCore

struct ServerSettingsView: View {
  @ObservedObject private var discovery = BonjourDiscovery.shared
  @ObservedObject private var wearablesVM: WearablesViewModel
  @Environment(\.dismiss) private var dismiss

  init(wearablesVM: WearablesViewModel) {
    self.wearablesVM = wearablesVM
  }

  var body: some View {
    RetraceScreen {
      ScrollView {
        VStack(spacing: Spacing.screenPadding) {
          glassesSection
          serverSection
          Spacer(minLength: 40)
        }
        .padding(Spacing.screenPadding)
      }
    }
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .retraceNavBar()
  }

  // MARK: - Glasses section

  @ViewBuilder
  private var glassesSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Glasses")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)
        .textCase(.uppercase)

      HStack(spacing: Spacing.md) {
        Circle()
          .fill(glassesStatusColor)
          .frame(width: 10, height: 10)
        Text(glassesStatusLabel)
          .font(.retraceCallout)
          .foregroundColor(.textPrimary)
        Spacer()
      }
      .padding(14)
      .background(Color.surfaceRaised)
      .cornerRadius(Radius.md)
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md)
          .stroke(Color.borderSubtle, lineWidth: 1)
      )

      CustomButton(
        title: wearablesVM.registrationState == .registering
          ? "Connecting…" : "Register new glasses",
        style: .primary,
        isDisabled: wearablesVM.registrationState == .registering
      ) {
        if wearablesVM.registrationState == .registered {
          wearablesVM.reRegisterGlasses()
        } else {
          wearablesVM.connectGlasses()
        }
      }
    }
    .padding(.top, Spacing.xl)
  }

  private var glassesStatusColor: Color {
    if wearablesVM.registrationState == .registering { return .yellow }
    return wearablesVM.hasActiveDevice ? .green : .textTertiary
  }

  private var glassesStatusLabel: String {
    if wearablesVM.registrationState == .registering { return "Connecting…" }
    return wearablesVM.hasActiveDevice ? "Connected" : "Not connected"
  }

  // MARK: - Server section

  @ViewBuilder
  private var serverSection: some View {
    VStack(spacing: Spacing.md) {
      VStack(spacing: Spacing.md) {
        Image(systemName: "server.rack")
          .font(.system(size: 40))
          .foregroundColor(.appPrimary)
        Text("Server Connection")
          .font(.retraceTitle2)
          .fontWeight(.bold)
          .foregroundColor(.textPrimary)
        Text("Retrace finds your server automatically on the local network.")
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
          .multilineTextAlignment(.center)
      }
      .padding(.top, Spacing.xl)

      serverStatusTile

      CustomButton(
        title: "Rescan",
        style: .secondary,
        isDisabled: false
      ) {
        discovery.rescan()
      }
    }
  }

  @ViewBuilder
  private var serverStatusTile: some View {
    HStack(alignment: .center, spacing: Spacing.md) {
      leadingIndicator
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(serverStatusLabel)
          .font(.retraceCallout)
          .foregroundColor(.textPrimary)
        if let url = discovery.discoveredURL {
          Text(url)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(.textSecondary)
        }
      }
      Spacer()
    }
    .padding(14)
    .background(Color.surfaceRaised)
    .cornerRadius(Radius.md)
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
  }

  @ViewBuilder
  private var leadingIndicator: some View {
    if discovery.discoveredURL == nil && discovery.isSearching {
      ProgressView()
        .tint(.appPrimary)
    } else {
      Circle()
        .fill(serverStatusColor)
        .frame(width: 10, height: 10)
    }
  }

  private var serverStatusColor: Color {
    if discovery.discoveredURL != nil {
      switch discovery.isReachable {
      case .some(true): return .green
      case .some(false): return .orange
      case .none: return .yellow
      }
    }
    return .textTertiary
  }

  private var serverStatusLabel: String {
    if discovery.discoveredURL != nil {
      switch discovery.isReachable {
      case .some(true): return "Connected"
      case .some(false): return "Unreachable"
      case .none: return "Checking…"
      }
    }
    if discovery.isSearching { return "Searching for server…" }
    return "Not connected"
  }
}
