import Foundation
import Network

@MainActor
final class BonjourDiscovery: ObservableObject {
  static let shared = BonjourDiscovery()

  @Published var discoveredURL: String?
  @Published var isSearching = false

  private var browser: NWBrowser?
  private let queue = DispatchQueue(label: "com.retrace.bonjour-discovery")

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

  private func handleResults(_ results: Set<NWBrowser.Result>) {
    guard let result = results.first else {
      discoveredURL = nil
      return
    }

    // Read hostname/host and port from the TXT record the server embeds.
    // Prefer `hostname` (a `.local` mDNS name) over `host` (a resolved IP): the
    // hostname survives DHCP rotation because the OS re-resolves it via mDNS
    // on every request, whereas a cached IP goes stale the moment the server's
    // lease rotates.
    if case .bonjour(let txtRecord) = result.metadata {
      let dict = txtRecordToDictionary(txtRecord)
      if let port = dict["port"] {
        if let hostname = dict["hostname"], !hostname.isEmpty {
          discoveredURL = "http://\(hostname):\(port)"
          return
        }
        if let host = dict["host"] {
          discoveredURL = "http://\(host):\(port)"
          return
        }
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
          }
        }
        connection.cancel()
      }
    }
    connection.start(queue: queue)
  }

  private func txtRecordToDictionary(_ txtRecord: NWTXTRecord) -> [String: String] {
    return txtRecord.dictionary
  }
}
