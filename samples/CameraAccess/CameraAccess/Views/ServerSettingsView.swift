import MWDATCore
import SwiftUI

struct ServerSettingsView: View {
  @ObservedObject private var discovery = BonjourDiscovery.shared
  @ObservedObject private var endpoint = ServerEndpoint.shared
  @ObservedObject private var wearablesVM: WearablesViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var healthState: HealthState = .idle
  @State private var lastRoundTripMs: Int?

  enum HealthState: Equatable {
    case idle
    case checking
    case ok
    case fail(String)
  }

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

  // MARK: - Glasses section (unchanged)

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
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Server")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)
        .textCase(.uppercase)

      activeEndpointTile

      modePicker

      if endpoint.mode == .custom {
        customURLField
      }

      if endpoint.mode == .auto || endpoint.mode == .local {
        CustomButton(
          title: discovery.isSearching ? "Rescanning…" : "Rescan Bonjour",
          style: .secondary,
          isDisabled: discovery.isSearching
        ) {
          discovery.rescan()
        }
      }

      CustomButton(
        title: healthState == .checking ? "Checking…" : "Test connection",
        style: .secondary,
        isDisabled: healthState == .checking
      ) {
        Task { await runHealthCheck() }
      }
    }
    .padding(.top, Spacing.xl)
  }

  @ViewBuilder
  private var activeEndpointTile: some View {
    HStack(alignment: .center, spacing: Spacing.md) {
      Circle()
        .fill(statusDotColor)
        .frame(width: 10, height: 10)
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.sm) {
          Text(endpoint.activeTier.displayName)
            .font(.retraceCallout)
            .fontWeight(.semibold)
            .foregroundColor(.textPrimary)
          if let ms = lastRoundTripMs, healthState == .ok {
            Text("· \(ms) ms")
              .font(.retraceCaption1)
              .foregroundColor(.textSecondary)
          }
          Spacer()
        }
        Text(endpoint.resolvedBaseURL)
          .font(.system(size: 13, design: .monospaced))
          .foregroundColor(.textSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
        if case .fail(let reason) = healthState {
          Text(reason)
            .font(.retraceCaption1)
            .foregroundColor(.orange)
        }
      }
      Spacer()
    }
    .padding(14)
    .background(Color.surfaceRaised)
    .cornerRadius(Radius.md)
  }

  private var statusDotColor: Color {
    switch healthState {
    case .ok: return .green
    case .fail: return .orange
    case .checking: return .yellow
    case .idle:
      switch endpoint.activeTier {
      case .bonjour, .cloud, .custom: return .textPrimary
      case .fallback: return .textTertiary
      }
    }
  }

  @ViewBuilder
  private var modePicker: some View {
    HStack(spacing: 0) {
      ForEach(ServerEndpoint.Mode.allCases) { mode in
        let isSelected = endpoint.mode == mode
        Button {
          if endpoint.mode != mode {
            endpoint.mode = mode
            healthState = .idle
            lastRoundTripMs = nil
          }
        } label: {
          Text(mode.displayName)
            .font(.retraceCallout)
            .fontWeight(isSelected ? .semibold : .medium)
            .foregroundColor(isSelected ? .backgroundPrimary : .textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xs)
            .background(
              RoundedRectangle(cornerRadius: Radius.sm)
                .fill(isSelected ? Color.textPrimary : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
      }
    }
    .padding(Radius.xs)
    .background(Color.surfaceBase)
    .cornerRadius(Radius.md)
  }

  @ViewBuilder
  private var customURLField: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      TextField("https://example.com:8000", text: $endpoint.manualURL)
        .textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
        .font(.system(size: 14, design: .monospaced))
        .onChange(of: endpoint.manualURL) { _, _ in
          healthState = .idle
          lastRoundTripMs = nil
        }
      if !endpoint.manualURL.isEmpty && !endpoint.isManualURLValid {
        Text("Enter an http:// or https:// URL with a host.")
          .font(.retraceCaption1)
          .foregroundColor(.orange)
      }
    }
  }

  // MARK: - Health check

  private func runHealthCheck() async {
    healthState = .checking
    lastRoundTripMs = nil

    guard let url = URL(string: "\(endpoint.resolvedBaseURL)/health") else {
      healthState = .fail("Invalid URL")
      return
    }

    var req = URLRequest(url: url)
    req.timeoutInterval = 5

    let start = Date()
    do {
      let (_, response) = try await URLSession.shared.data(for: req)
      let elapsed = Int(Date().timeIntervalSince(start) * 1000)
      if let http = response as? HTTPURLResponse, http.statusCode == 200 {
        lastRoundTripMs = elapsed
        healthState = .ok
      } else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        healthState = .fail("Server responded with \(code)")
      }
    } catch {
      healthState = .fail(error.localizedDescription)
    }
  }
}
