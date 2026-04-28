import SwiftUI

/// One row in the "Sources" footer on a procedure detail view. Renders
/// title + domain + chevron; tap action opens the URL in
/// `SafariBrowserView`. The domain hint is computed from the URL host
/// — for Vertex grounding-redirect URLs (`vertexaisearch.cloud.google.com`)
/// we fall back to the title field, which the backend populates with the
/// real source domain (e.g. `reddit.com`, `ifixit.com`).
struct SourceRow: View {
  let source: OnlineSource
  let action: () -> Void

  private var displayDomain: String {
    if let host = URL(string: source.url)?.host,
       !host.contains("vertexaisearch") {
      return host.replacingOccurrences(of: "www.", with: "")
    }
    // Backend stores the real source domain in `title` for grounded URLs.
    return source.title
  }

  /// Pick a single SF Symbol that hints at the source kind.
  private var domainIcon: String {
    let lower = displayDomain.lowercased()
    if lower.contains("reddit") { return "bubble.left.and.bubble.right.fill" }
    if lower.contains("ifixit") { return "wrench.and.screwdriver.fill" }
    if lower.contains("youtube") { return "play.rectangle.fill" }
    if lower.contains("github") { return "chevron.left.forwardslash.chevron.right" }
    return "link"
  }

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: Spacing.lg) {
        Image(systemName: domainIcon)
          .font(.system(size: 18, weight: .medium))
          .foregroundColor(.textSecondary)
          .frame(width: 28)

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(displayDomain)
            .font(.retraceFace(.semibold, size: 15))
            .foregroundColor(.textPrimary)
            .lineLimit(1)
          if !source.snippet.isEmpty {
            Text(source.snippet)
              .font(.retraceCaption1)
              .foregroundColor(.textSecondary)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
          }
        }

        Spacer(minLength: Spacing.md)

        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(.textTertiary)
      }
      .padding(Spacing.lg)
      .background(Color.surfaceBase)
      .cornerRadius(Radius.md)
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md)
          .stroke(Color.borderSubtle, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }
}
