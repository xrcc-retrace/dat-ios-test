import SwiftUI
import UIKit

struct ProcedureCardView: View {
  let title: String
  let description: String
  let stepCount: Int
  let duration: Double
  let createdAt: String
  let status: String?
  let iconSymbol: String?
  let iconEmoji: String?

  init(
    title: String,
    description: String,
    stepCount: Int,
    duration: Double,
    createdAt: String,
    status: String?,
    iconSymbol: String? = nil,
    iconEmoji: String? = nil
  ) {
    self.title = title
    self.description = description
    self.stepCount = stepCount
    self.duration = duration
    self.createdAt = createdAt
    self.status = status
    self.iconSymbol = iconSymbol
    self.iconEmoji = iconEmoji
  }

  var body: some View {
    HStack(spacing: Spacing.xl) {
      statusBadge
        .frame(width: 40, height: 40)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text(title)
          .font(.retraceHeadline)
          .foregroundColor(.textPrimary)
          .lineLimit(1)

        Text(description)
          .font(.retraceSubheadline)
          .foregroundColor(.textSecondary)
          .lineLimit(2)

        HStack(spacing: Spacing.md) {
          MetadataPill(icon: "clock", text: formattedDuration)
          MetadataPill(icon: "list.number", text: "\(stepCount) steps")
        }
      }

      Spacer()

      Image(systemName: "chevron.right")
        .font(.retraceSubheadline)
        .foregroundColor(.textTertiary)
    }
    .padding(Spacing.xxl)
    .background(Color.surfaceBase)
    .cornerRadius(Radius.lg)
  }

  @ViewBuilder
  private var statusBadge: some View {
    if status == "processing" {
      Circle()
        .fill(Color.iconSurface)
        .overlay(
          ProgressView()
            .scaleEffect(0.7)
            .tint(.textPrimary)
        )
    } else {
      Circle()
        .fill(Color.surfaceRaised)
        .overlay(iconContent)
    }
  }

  /// Always-white branded icon. The server returns a `lucide:wrench` PNG
  /// transparently when the picked Iconify ID 404s, so we never need a
  /// colored emoji on this badge — emojis aren't tintable on iOS (Apple
  /// Color Emoji is a bitmap font), so they'd break the white-only design.
  /// Only when the entire icon URL fails to load (e.g. server unreachable)
  /// do we fall through to the step count as a defensive last resort.
  @ViewBuilder
  private var iconContent: some View {
    AsyncImage(url: iconURL) { phase in
      switch phase {
      case .success(let image):
        image
          .resizable()
          .renderingMode(.template)
          .scaledToFit()
          .foregroundColor(.textPrimary)
          .frame(width: 22, height: 22)
      case .empty, .failure:
        // .empty: brief loading flicker — render nothing (server PNG arrives fast).
        // .failure: only when the server itself is unreachable; show step count
        //           rather than a colored emoji that would break branding.
        if case .failure = phase {
          stepCountFallback
        } else {
          Color.clear
        }
      @unknown default:
        stepCountFallback
      }
    }
  }

  @ViewBuilder
  private var stepCountFallback: some View {
    Text("\(stepCount)")
      .font(Font.retraceHeadline)
      .fontWeight(.bold)
      .foregroundColor(.textPrimary)
  }

  /// Builds the server-side icon endpoint URL. If `iconSymbol` parses as a
  /// valid Iconify ID (`prefix:name`), use it directly. Otherwise request
  /// the generic `lucide:wrench` fallback so the badge always renders a
  /// branded white icon — never a colored emoji.
  private var iconURL: URL? {
    let base = ServerEndpoint.shared.resolvedBaseURL
    if let (prefix, name) = parsedIconID {
      return URL(string: "\(base)/api/icons/\(prefix)/\(name).png")
    }
    return URL(string: "\(base)/api/icons/lucide/wrench.png")
  }

  private var parsedIconID: (String, String)? {
    guard let symbol = iconSymbol, !symbol.isEmpty else { return nil }
    let parts = symbol.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
    guard parts.count == 2 else { return nil }
    let prefix = String(parts[0])
    let name = String(parts[1])
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
    guard !prefix.isEmpty,
          !name.isEmpty,
          prefix.unicodeScalars.allSatisfy({ allowed.contains($0) }),
          name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      return nil
    }
    return (prefix, name)
  }

  private var formattedDuration: String {
    let mins = Int(duration) / 60
    let secs = Int(duration) % 60
    return String(format: "%d:%02d", mins, secs)
  }
}
