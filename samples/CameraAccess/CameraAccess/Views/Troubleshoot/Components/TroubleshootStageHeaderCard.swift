import SwiftUI

/// Main card for every Troubleshoot lens page. Mirrors coaching's
/// `RayBanHUDStepCard` in size and typography (padding 20pt, corner
/// radius 24pt, title 20pt bold, body 18pt medium, glass panel) so
/// the two flows feel like siblings.
///
/// Three slots:
/// - `stage` — drives the overline label ("IDENTIFY" / "DIAGNOSE" /
///   "FIND A FIX"). The icon for the stage no longer appears inside
///   the card; the in-lens 3-segment progress bar at the bottom of
///   the page already names the active stage at a glance.
/// - `title` — primary line, 20pt bold (matches step title)
/// - `body` — secondary line, 18pt medium (matches step description)
/// - `accessory` — optional trailing content for spinners / animated
///   graphics that some pages need (library spinner, web search
///   graphic). When nil the card is title + body only.
struct TroubleshootStageHeaderCard<Accessory: View>: View {
  enum Stage {
    case identify
    case diagnose
    case findFix

    var label: String {
      switch self {
      case .identify: return "IDENTIFY"
      case .diagnose: return "DIAGNOSE"
      case .findFix:  return "FIND A FIX"
      }
    }

    /// SF Symbol that pairs with the stage label inside the card.
    /// Mirrors the icons in `DiagnosticPhaseBar` so the lens shows the
    /// same visual vocabulary at the top of the card and at the
    /// progress bar — user reads the stage from either surface.
    var icon: String {
      switch self {
      case .identify: return "camera.viewfinder"
      case .diagnose: return "magnifyingglass"
      case .findFix:  return "globe"
      }
    }
  }

  let stage: Stage
  let title: String
  let bodyText: String?
  @ViewBuilder let accessory: () -> Accessory

  init(
    stage: Stage,
    title: String,
    bodyText: String? = nil,
    @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
  ) {
    self.stage = stage
    self.title = title
    self.bodyText = bodyText
    self.accessory = accessory
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: stage.icon)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.white.opacity(0.9))
        Text(stage.label)
          .font(.inter(.medium, size: 12))
          .tracking(1.2)
          .foregroundStyle(Color.white.opacity(0.9))
      }

      Text(title)
        .font(.inter(.bold, size: 20))
        .foregroundStyle(Color.white.opacity(0.98))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)

      if let bodyText, !bodyText.isEmpty {
        Text(bodyText)
          .font(.inter(.medium, size: 18))
          .foregroundStyle(Color.white.opacity(0.96))
          .lineSpacing(2)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }

      let accessoryView = accessory()
      if !(accessoryView is EmptyView) {
        accessoryView
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(RayBanHUDLayoutTokens.contentPadding)
    .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
  }
}
