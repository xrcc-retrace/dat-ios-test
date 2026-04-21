import Combine
import Foundation

/// Central resolver for the Retrace server URL.
///
/// Four modes drive a priority chain:
/// - `.custom` — user-entered `manualURL`
/// - `.cloud`  — compiled-in `cloudBaseURL` (DuckDNS / prod demo box)
/// - `.local`  — Bonjour-discovered URL only
/// - `.auto`   — Bonjour first, fall back to cloud if nothing discovered
///
/// `.local` and `.auto` fall through to the LAN default if nothing resolves,
/// so `resolvedBaseURL` is always a non-nil callable string. The class also
/// mirrors the resolved value into `UserDefaults["serverBaseURL"]` so legacy
/// callers reading that key continue to get the current URL without any
/// refactor.
@MainActor
final class ServerEndpoint: ObservableObject {
  static let shared = ServerEndpoint()

  enum Mode: String, CaseIterable, Identifiable {
    case auto, local, cloud, custom
    var id: String { rawValue }
    var displayName: String {
      switch self {
      case .auto: return "Auto"
      case .local: return "Local"
      case .cloud: return "Cloud"
      case .custom: return "Custom"
      }
    }
  }

  enum Tier: String {
    case bonjour, cloud, custom, fallback
    var displayName: String {
      switch self {
      case .bonjour: return "Bonjour"
      case .cloud: return "Cloud"
      case .custom: return "Custom"
      case .fallback: return "Fallback"
      }
    }
  }

  // Compile-time defaults. Update `cloudBaseURL` when the DuckDNS hostname
  // or (later) the Route53 domain changes.
  static let cloudBaseURL = "https://retracexrcc.duckdns.org"
  static let lanFallbackURL = "http://192.168.1.100:8000"

  private static let legacyURLKey = "serverBaseURL"
  private static let modeKey = "serverMode"
  private static let manualURLKey = "manualServerURL"

  @Published private(set) var resolvedBaseURL: String = ServerEndpoint.lanFallbackURL
  @Published private(set) var activeTier: Tier = .fallback

  @Published var mode: Mode {
    didSet {
      guard mode != oldValue else { return }
      UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
      recompute()
    }
  }

  @Published var manualURL: String {
    didSet {
      guard manualURL != oldValue else { return }
      UserDefaults.standard.set(manualURL, forKey: Self.manualURLKey)
      recompute()
    }
  }

  private var cancellables: Set<AnyCancellable> = []

  private init() {
    let storedMode = UserDefaults.standard.string(forKey: Self.modeKey)
      .flatMap(Mode.init(rawValue:)) ?? .auto
    self.mode = storedMode
    self.manualURL = UserDefaults.standard.string(forKey: Self.manualURLKey) ?? ""

    BonjourDiscovery.shared.$discoveredURL
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.recompute()
      }
      .store(in: &cancellables)

    recompute()
  }

  /// Recomputes `resolvedBaseURL` and `activeTier` from current inputs.
  /// Called automatically on mode/manual/discoveredURL changes; exposed so
  /// tests or debug menus can force a refresh.
  func recompute() {
    let discovered = BonjourDiscovery.shared.discoveredURL
    let trimmedManual = manualURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let manualValid = Self.validateURLString(trimmedManual)

    let (url, tier): (String, Tier)
    switch mode {
    case .custom:
      if manualValid {
        (url, tier) = (trimmedManual, .custom)
      } else {
        (url, tier) = (Self.lanFallbackURL, .fallback)
      }
    case .cloud:
      (url, tier) = (Self.cloudBaseURL, .cloud)
    case .local:
      if let discovered {
        (url, tier) = (discovered, .bonjour)
      } else {
        (url, tier) = (Self.lanFallbackURL, .fallback)
      }
    case .auto:
      if let discovered {
        (url, tier) = (discovered, .bonjour)
      } else {
        (url, tier) = (Self.cloudBaseURL, .cloud)
      }
    }

    if url != resolvedBaseURL {
      resolvedBaseURL = url
      UserDefaults.standard.set(url, forKey: Self.legacyURLKey)
    }
    if tier != activeTier {
      activeTier = tier
    }
  }

  /// True iff `manualURL` parses into a URL with an http(s) scheme.
  var isManualURLValid: Bool {
    Self.validateURLString(manualURL.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func validateURLString(_ raw: String) -> Bool {
    guard !raw.isEmpty, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty
    else {
      return false
    }
    return true
  }
}
