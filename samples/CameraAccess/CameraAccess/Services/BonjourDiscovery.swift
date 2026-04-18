import Foundation
import Network

@MainActor
final class BonjourDiscovery: ObservableObject {
  static let shared = BonjourDiscovery()

  @Published var discoveredURL: String? {
    didSet {
      guard discoveredURL != oldValue else { return }
      if discoveredURL != nil {
        startHealthPolling()
      } else {
        stopHealthPolling()
      }
    }
  }
  @Published var isSearching = false
  /// nil = no URL yet / not pinged; true = last /health returned 200;
  /// false = /health failed or timed out. Use in combination with
  /// `discoveredURL` + `isSearching` to derive the UI status.
  @Published var isReachable: Bool?

  private var browser: NWBrowser?
  private var healthTask: Task<Void, Never>?
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

  /// Manual re-scan triggered from Settings. Cancels the current browser and
  /// starts a fresh one so results repopulate from scratch.
  func rescan() {
    stopBrowsing()
    discoveredURL = nil
    startBrowsing()
  }

  // MARK: - Health polling

  private func startHealthPolling() {
    healthTask?.cancel()
    healthTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, let base = self.discoveredURL,
          let url = URL(string: "\(base)/health")
        else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        do {
          let (_, response) = try await URLSession.shared.data(for: req)
          let ok = (response as? HTTPURLResponse)?.statusCode == 200
          self.isReachable = ok
        } catch {
          self.isReachable = false
        }
        try? await Task.sleep(nanoseconds: 5_000_000_000)
      }
    }
  }

  private func stopHealthPolling() {
    healthTask?.cancel()
    healthTask = nil
    isReachable = nil
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
