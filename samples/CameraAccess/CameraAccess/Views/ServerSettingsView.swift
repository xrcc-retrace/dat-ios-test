import MWDATCore
import SwiftUI

// MARK: - Combined screen (used by ModeSelectionView's gear icon)

struct ServerSettingsView: View {
  @ObservedObject var wearablesVM: WearablesViewModel

  var body: some View {
    RetraceScreen {
      ScrollView {
        VStack(spacing: Spacing.screenPadding) {
          GlassesSettingsSection(wearablesVM: wearablesVM)
          ServerSettingsSection()
          DebugSettingsSection()
          Spacer(minLength: 40)
        }
        .padding(Spacing.screenPadding)
      }
    }
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .retraceNavBar()
  }
}

// MARK: - Debug section

/// Single-toggle debug surface. Read via `@AppStorage("debugMode")`
/// anywhere in the app — the toggle drives the Ray-Ban lens boundary
/// outline, the hand-tracking landmark overlay, and any other dev-only
/// inspection UI we add later. One switch, one source of truth.
struct DebugSettingsSection: View {
  @AppStorage("debugMode") private var debugMode: Bool = false
  @AppStorage("hudAdditiveBlend") private var hudAdditiveBlend: Bool = false
  /// When true, hand-gesture-driven inputs are silenced across every
  /// mode. Read at session start by both `startHandTrackingIfAvailable`
  /// sites (Expert + GeminiLive base) — MediaPipe doesn't even spin
  /// up when the flag is on. Also re-read inside `HandGestureService.ingest(_:)`
  /// so flipping the toggle mid-session takes effect immediately
  /// without a restart. Touch + lens swipes still work; only the
  /// pinch / micro-gesture path is muted.
  @AppStorage("disableHandTracking") private var disableHandTracking: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Debug")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)
        .textCase(.uppercase)

      Toggle(isOn: $debugMode) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Debug mode")
            .font(.retraceCallout)
            .foregroundColor(.textPrimary)
          Text("Shows the Ray-Ban lens boundary, hand-tracking landmarks, and other developer overlays during sessions.")
            .font(.retraceCaption1)
            .foregroundColor(.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .tint(.appPrimary)
      .padding(14)
      .background(Color.surfaceRaised)
      .cornerRadius(Radius.md)

      Toggle(isOn: $hudAdditiveBlend) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Additive HUD blending")
            .font(.retraceCallout)
            .foregroundColor(.textPrimary)
          Text("Renders the Ray-Ban lens with additive (plus-lighter) blending so dark pixels show the camera through and bright pixels brighten what's behind — the same optical behavior as the real Meta Ray-Ban Display. Bright scenes will wash out panels.")
            .font(.retraceCaption1)
            .foregroundColor(.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .tint(.appPrimary)
      .padding(14)
      .background(Color.surfaceRaised)
      .cornerRadius(Radius.md)

      Toggle(isOn: $disableHandTracking) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Disable hand tracking")
            .font(.retraceCallout)
            .foregroundColor(.textPrimary)
          Text("Silences the MediaPipe pinch-drag and micro-gesture pipeline across Expert, Coaching, and Troubleshoot. Touch swipes and taps still work. Useful when running without good lighting or when you'd rather drive the HUD purely from touch.")
            .font(.retraceCaption1)
            .foregroundColor(.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .tint(.appPrimary)
      .padding(14)
      .background(Color.surfaceRaised)
      .cornerRadius(Radius.md)

    }
    .padding(.top, Spacing.xl)
  }
}

// MARK: - Glasses section (reusable)

struct GlassesSettingsSection: View {
  @ObservedObject var wearablesVM: WearablesViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Glasses")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)
        .textCase(.uppercase)

      HStack(spacing: Spacing.md) {
        Circle()
          .fill(statusColor)
          .frame(width: 10, height: 10)
        Text(statusLabel)
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

  private var statusColor: Color {
    if wearablesVM.registrationState == .registering { return .yellow }
    return wearablesVM.hasActiveDevice ? .green : .textTertiary
  }

  private var statusLabel: String {
    if wearablesVM.registrationState == .registering { return "Connecting…" }
    return wearablesVM.hasActiveDevice ? "Connected" : "Not connected"
  }
}

// MARK: - Server section (reusable)

struct ServerSettingsSection: View {
  @ObservedObject private var discovery = BonjourDiscovery.shared
  @ObservedObject private var endpoint = ServerEndpoint.shared

  @State private var healthState: HealthState = .idle
  @State private var lastRoundTripMs: Int?

  enum HealthState: Equatable {
    case idle
    case checking
    case ok
    case fail(String)
  }

  var body: some View {
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
