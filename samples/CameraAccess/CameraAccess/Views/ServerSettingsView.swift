import SwiftUI
import Network

struct ServerSettingsView: View {
  @State private var serverAddress: String
  @State private var showHelpTip = false
  @State private var deviceIP: String?
  @State private var showSaved = false
  @ObservedObject private var discovery = BonjourDiscovery.shared
  @Environment(\.dismiss) private var dismiss

  private static let serverURLKey = "serverBaseURL"
  private static let defaultServerURL = "http://192.168.1.100:8000"

  init() {
    let saved = UserDefaults.standard.string(forKey: Self.serverURLKey) ?? Self.defaultServerURL
    let display = saved
      .replacingOccurrences(of: "http://", with: "")
      .replacingOccurrences(of: "https://", with: "")
    _serverAddress = State(initialValue: display)
  }

  var body: some View {
    ZStack {
      Color.backgroundPrimary.edgesIgnoringSafeArea(.all)

      ScrollView {
        VStack(spacing: Spacing.screenPadding) {
          // Header
          VStack(spacing: Spacing.md) {
            Image(systemName: "server.rack")
              .font(.system(size: 40))
              .foregroundColor(.appPrimary)
            Text("Server Connection")
              .font(.retraceTitle2)
              .fontWeight(.bold)
              .foregroundColor(.textPrimary)
            Text("Enter your Mac's local IP address and port")
              .font(.retraceCallout)
              .foregroundColor(.textSecondary)
          }
          .padding(.top, Spacing.xl)

          // IP Input
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Server Address")
              .font(.retraceOverline)
              .tracking(0.5)
              .foregroundColor(.textSecondary)
              .textCase(.uppercase)

            HStack {
              Text("http://")
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(.textTertiary)
              TextField("192.168.1.100:8000", text: $serverAddress)
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(.textPrimary)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            }
            .padding(14)
            .background(Color.surfaceRaised)
            .cornerRadius(Radius.md)
            .overlay(
              RoundedRectangle(cornerRadius: Radius.md)
                .stroke(Color.borderSubtle, lineWidth: 1)
            )
          }

          // Quick-fill: device's own IP
          if let deviceIP {
            VStack(alignment: .leading, spacing: Spacing.md) {
              Text("Your Device's Network")
                .font(.retraceOverline)
                .tracking(0.5)
                .foregroundColor(.textSecondary)
                .textCase(.uppercase)

              Button {
                let port = serverAddress.components(separatedBy: ":").last ?? "8000"
                let hasPort = serverAddress.contains(":")
                serverAddress = deviceIP + (hasPort ? ":\(port)" : ":8000")
              } label: {
                HStack {
                  Image(systemName: "wifi")
                    .foregroundColor(.appPrimary)
                  Text(deviceIP)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(.textPrimary)
                  Spacer()
                  Text("Use subnet")
                    .font(.retraceCaption1)
                    .foregroundColor(.appPrimary)
                }
                .padding(14)
                .background(Color.surfaceBase)
                .cornerRadius(Radius.md)
                .overlay(
                  RoundedRectangle(cornerRadius: Radius.md)
                    .stroke(Color.borderSubtle, lineWidth: 1)
                )
              }
            }
          }

          // Auto-discovered server
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Auto-Discovered Server")
              .font(.retraceOverline)
              .tracking(0.5)
              .foregroundColor(.textSecondary)
              .textCase(.uppercase)

            if let discovered = discovery.discoveredURL {
              Button {
                let stripped = discovered
                  .replacingOccurrences(of: "http://", with: "")
                  .replacingOccurrences(of: "https://", with: "")
                serverAddress = stripped
                BonjourDiscovery.clearUserOverride()
                UserDefaults.standard.set(discovered, forKey: Self.serverURLKey)
                showSaved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                  showSaved = false
                }
              } label: {
                HStack {
                  Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                  Text(discovered)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(.textPrimary)
                  Spacer()
                  Text("Use")
                    .font(.retraceCaption1)
                    .foregroundColor(.appPrimary)
                }
                .padding(14)
                .background(Color.surfaceBase)
                .cornerRadius(Radius.md)
                .overlay(
                  RoundedRectangle(cornerRadius: Radius.md)
                    .stroke(Color.borderSubtle, lineWidth: 1)
                )
              }
            } else if discovery.isSearching {
              HStack(spacing: Spacing.md) {
                ProgressView()
                  .tint(.appPrimary)
                Text("Searching for server...")
                  .font(.retraceCallout)
                  .foregroundColor(.textSecondary)
              }
              .padding(14)
            } else {
              Text("Not searching")
                .font(.retraceCallout)
                .foregroundColor(.textTertiary)
                .padding(14)
            }
          }

          // Save button
          CustomButton(
            title: showSaved ? "Saved!" : "Save",
            style: .primary,
            isDisabled: serverAddress.isEmpty
          ) {
            let url = "http://\(serverAddress)"
            UserDefaults.standard.set(url, forKey: Self.serverURLKey)
            BonjourDiscovery.markUserOverride()
            showSaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
              showSaved = false
            }
          }

          // Help tip
          VStack(alignment: .leading, spacing: Spacing.lg) {
            Button {
              withAnimation { showHelpTip.toggle() }
            } label: {
              HStack {
                Image(systemName: "questionmark.circle")
                  .foregroundColor(.appPrimary)
                Text("How to find your Mac's IP address")
                  .font(.retraceCallout)
                  .fontWeight(.medium)
                  .foregroundColor(.appPrimary)
                Spacer()
                Image(systemName: showHelpTip ? "chevron.up" : "chevron.down")
                  .font(.retraceCaption1)
                  .foregroundColor(.textTertiary)
              }
            }

            if showHelpTip {
              VStack(alignment: .leading, spacing: Spacing.xl) {
                HelpStep(
                  number: 1,
                  title: "Using System Settings",
                  detail: "Open System Settings \u{2192} Network \u{2192} Wi-Fi \u{2192} Details. Your IP is listed under \"IP Address\"."
                )
                HelpStep(
                  number: 2,
                  title: "Using Terminal",
                  detail: "Open Terminal and run:\nipconfig getifaddr en0\n\nThis prints your Wi-Fi IP address."
                )
                HelpStep(
                  number: 3,
                  title: "Using Menu Bar",
                  detail: "Hold \u{2325} Option and click the Wi-Fi icon in the menu bar. Your IP is shown directly."
                )

                Text("Make sure your phone and Mac are on the same Wi-Fi network.")
                  .font(.retraceSubheadline)
                  .foregroundColor(.appPrimary)
                  .padding(.top, Spacing.xs)
              }
              .padding(14)
              .background(Color.surfaceBase)
              .cornerRadius(Radius.md)
              .transition(.opacity.combined(with: .move(edge: .top)))
            }
          }

          Spacer(minLength: 40)
        }
        .padding(Spacing.screenPadding)
      }
    }
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(Color.backgroundPrimary, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .onAppear {
      fetchDeviceIP()
    }
  }

  private func fetchDeviceIP() {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return }
    defer { freeifaddrs(ifaddr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
      let interface = ptr.pointee
      let addrFamily = interface.ifa_addr.pointee.sa_family
      if addrFamily == UInt8(AF_INET) {
        let name = String(cString: interface.ifa_name)
        if name == "en0" {
          var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
          getnameinfo(
            interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
            &hostname, socklen_t(hostname.count),
            nil, socklen_t(0), NI_NUMERICHOST
          )
          address = String(cString: hostname)
        }
      }
    }
    deviceIP = address
  }
}

// MARK: - Help Step

private struct HelpStep: View {
  let number: Int
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Text("\(number)")
        .font(.system(size: 13, weight: .bold, design: .monospaced))
        .foregroundColor(.appPrimary)
        .frame(width: 22, height: 22)
        .background(Color.accentMuted)
        .cornerRadius(Radius.sm)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(title)
          .font(.retraceCallout)
          .fontWeight(.semibold)
          .foregroundColor(.textPrimary)
        Text(detail)
          .font(.retraceSubheadline)
          .foregroundColor(.textSecondary)
      }
    }
  }
}
