import Foundation
import Network

@MainActor
final class BonjourDiscovery: ObservableObject {
  static let shared = BonjourDiscovery()

  @Published var discoveredURL: String?
  @Published var isSearching = false

  private var browser: NWBrowser?
  private let queue = DispatchQueue(label: "com.retrace.bonjour-discovery")

  private static let serverURLKey = "serverBaseURL"
  private static let userOverrideKey = "userOverrodeServerURL"

  private init() {}

  func startBrowsing() {
    guard browser == nil else { return }

    let descriptor = NWBrowser.Descriptor.bonjour(
      type: "_retrace._tcp",
      domain: "local."
    )
    let params = NWParameters()
    params.includePeerToPeer = true

    let browser = NWBrowser(for: descriptor, using: params)
    self.browser = browser

    browser.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        switch state {
        case .ready:
          self?.isSearching = true
        case .failed, .cancelled:
          self?.isSearching = false
          self?.discoveredURL = nil
        default:
          break
        }
      }
    }

    browser.browseResultsChangedHandler = { [weak self] results, _ in
      Task { @MainActor in
        self?.handleResults(results)
      }
    }

    browser.start(queue: queue)
  }

  func stopBrowsing() {
    browser?.cancel()
    browser = nil
    isSearching = false
  }

  private func handleResults(_ results: Set<NWBrowser.Result>) {
    guard let result = results.first else {
      discoveredURL = nil
      return
    }

    // Read host and port from the TXT record the server embeds
    if case .bonjour(let txtRecord) = result.metadata {
      let dict = txtRecordToDictionary(txtRecord)
      if let host = dict["host"], let port = dict["port"] {
        let url = "http://\(host):\(port)"
        discoveredURL = url
        applyIfNotOverridden(url)
        return
      }
    }

    // No TXT record or missing keys — fallback to connection resolution
    resolveViaConnection(result)
  }

  private func resolveViaConnection(_ result: NWBrowser.Result) {
    let connection = NWConnection(to: result.endpoint, using: .tcp)
    connection.stateUpdateHandler = { [weak self] state in
      if case .ready = state {
        if let innerEndpoint = connection.currentPath?.remoteEndpoint,
          case .hostPort(let host, let port) = innerEndpoint
        {
          // Strip IPv6 zone ID (e.g. "%en0") if present
          let hostStr = "\(host)"
            .replacingOccurrences(of: "%.*", with: "", options: .regularExpression)
          let url = "http://\(hostStr):\(port)"
          Task { @MainActor in
            self?.discoveredURL = url
            self?.applyIfNotOverridden(url)
          }
        }
        connection.cancel()
      }
    }
    connection.start(queue: queue)
  }

  private func applyIfNotOverridden(_ url: String) {
    let overridden = UserDefaults.standard.bool(forKey: Self.userOverrideKey)
    if !overridden {
      UserDefaults.standard.set(url, forKey: Self.serverURLKey)
    }
  }

  private func txtRecordToDictionary(_ txtRecord: NWTXTRecord) -> [String: String] {
    // NWTXTRecord.dictionary returns [String: String]
    return txtRecord.dictionary
  }

  /// Mark that the user manually set the server URL
  static func markUserOverride() {
    UserDefaults.standard.set(true, forKey: userOverrideKey)
  }

  /// Clear the manual override so auto-discovery takes effect again
  static func clearUserOverride() {
    UserDefaults.standard.set(false, forKey: userOverrideKey)
  }
}
