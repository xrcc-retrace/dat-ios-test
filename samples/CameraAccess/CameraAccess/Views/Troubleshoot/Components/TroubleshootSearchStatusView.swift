import SwiftUI

/// Single status surface for the troubleshoot search flow. Reads
/// `viewModel.searchNarration` and renders one of five moments:
///
/// - `.searchingLibrary` — title + body + animated ellipsis
/// - `.libraryMissed`    — title + body, no ellipsis (deliberate
///                         3-second static moment so the user
///                         registers the miss before being whisked
///                         into the next phase)
/// - `.searchingWeb`     — title + body + animated ellipsis
/// - `.synthesizing`     — title + "Found N sources …" + ellipsis
///                         (server-driven via web_search_progress poll)
/// - `.foundFix`         — brief success flash with checkmark before
///                         the resolution panel arrives
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
      case .synthesizing(let count):
        TroubleshootStageHeaderCard(
          stage: .findFix,
          title: "Synthesizing the procedure",
          bodyText: synthesizingBody(count: count)
        ) {
          synthesizingAccessory
        }
        .id("synthesizing")
      case .foundFix(let count):
        TroubleshootStageHeaderCard(
          stage: .findFix,
          title: "Solution found",
          bodyText: foundFixBody(count: count)
        ) {
          foundFixAccessory
        }
        .id("foundFix")
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

  private var synthesizingAccessory: some View {
    VStack(spacing: 8) {
      HStack(spacing: 4) {
        Image(systemName: "clock")
          .font(.system(size: 11, weight: .medium))
        Text("Est. 10-15 seconds")
          .font(.retraceCaption2)
      }
      .foregroundStyle(.white.opacity(0.6))
      AnimatedEllipsis()
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }

  private var foundFixAccessory: some View {
    HStack(spacing: 6) {
      Image(systemName: "checkmark")
        .font(.system(size: 14, weight: .semibold))
      Text("Drafted")
        .font(.retraceCaption1)
    }
    .foregroundStyle(.white.opacity(0.9))
    .padding(.vertical, 8)
  }

  private func synthesizingBody(count: Int) -> String {
    let plural = count == 1 ? "" : "s"
    return "Found \(count) source\(plural) on Reddit, iFixit, repair forums."
  }

  private func foundFixBody(count: Int) -> String {
    let plural = count == 1 ? "" : "s"
    return "From \(count) online source\(plural)."
  }
}
