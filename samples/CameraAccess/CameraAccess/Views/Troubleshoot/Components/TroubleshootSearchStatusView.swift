import SwiftUI

/// Single status surface for the troubleshoot search flow. Reads
/// `viewModel.searchNarration` and renders one of three moments:
///
/// - `.searchingLibrary` — title + body + animated ellipsis
/// - `.libraryMissed`    — title + body, no ellipsis (deliberate
///                         3-second static moment so the user
///                         registers the miss before being whisked
///                         into the next phase)
/// - `.searchingWeb`     — title + body + animated ellipsis
///
/// Replaces the previous bespoke spinner-vs-WebSearchGraphic split in
/// `TroubleshootSearchingPage` with one consistent voice.
struct TroubleshootSearchStatusView: View {
  @ObservedObject var viewModel: DiagnosticSessionViewModel

  var body: some View {
    Group {
      switch viewModel.searchNarration {
      case .libraryMissed:
        TroubleshootStageHeaderCard(
          stage: .findFix,
          title: "No procedure found in your library.",
          bodyText: "Looking online next."
        )
        .id("libraryMissed")
      case .searchingWeb:
        TroubleshootStageHeaderCard(
          stage: .findFix,
          title: "Searching online",
          bodyText: "Reddit, iFixit, repair forums."
        ) {
          ellipsisRow
        }
        .id("searchingWeb")
      case .searchingLibrary, .none:
        TroubleshootStageHeaderCard(
          stage: .findFix,
          title: "Searching your library",
          bodyText: "Checking your saved procedures."
        ) {
          ellipsisRow
        }
        .id("searchingLibrary")
      }
    }
    .transition(.asymmetric(
      insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)),
      removal: .opacity
    ))
  }

  private var ellipsisRow: some View {
    HStack {
      Spacer()
      AnimatedEllipsis()
      Spacer()
    }
    .padding(.vertical, 8)
  }
}
