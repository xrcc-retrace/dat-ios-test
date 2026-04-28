import SafariServices
import SwiftUI

/// `URL` does not conform to `Identifiable` on its own, so callers using
/// `.sheet(item:)` to present `SafariBrowserView` wrap the URL in this
/// shim. The URL string is the identity — re-presenting the same URL
/// keeps the same sheet alive instead of remounting.
struct IdentifiableURL: Identifiable, Hashable {
  let url: URL
  var id: String { url.absoluteString }
}

/// Thin SwiftUI wrapper around `SFSafariViewController`. Bind it to a
/// `@State var selectedURL: IdentifiableURL?` and present via
/// `.sheet(item:)`.
///
/// Used by `LearnerProcedureDetailView` when the user taps a source row
/// in the procedure's "Sources" footer. `SFSafariViewController` keeps
/// the user inside Retrace (vs. bouncing out to Safari.app) and follows
/// the Vertex grounding-redirect URLs Gemini returns in
/// `procedure.sources[].url` transparently.
struct SafariBrowserView: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> SFSafariViewController {
    let config = SFSafariViewController.Configuration()
    config.entersReaderIfAvailable = false
    let vc = SFSafariViewController(url: url, configuration: config)
    vc.preferredControlTintColor = UIColor(named: "TextPrimary") ?? .label
    return vc
  }

  func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
    // SFSafariViewController is initialized once per URL; nothing to update
    // when the parent re-renders.
  }
}
