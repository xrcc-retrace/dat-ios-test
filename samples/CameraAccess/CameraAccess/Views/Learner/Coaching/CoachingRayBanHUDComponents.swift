import AVKit
import SwiftUI

enum RayBanHUDStepCardMode {
  case content(stepIndex: Int, stepCount: Int, step: ProcedureStepResponse?, isExpanded: Bool)
  case loading(stepIndex: Int?, stepCount: Int)
}

enum InsightCategory: String, CaseIterable, Hashable {
  case tips
  case warnings
  case redFlags

  var displayName: String {
    switch self {
    case .tips: return "Tips"
    case .warnings: return "Warnings"
    case .redFlags: return "Red Flags"
    }
  }

  func items(for step: ProcedureStepResponse) -> [String] {
    switch self {
    case .tips: return step.tips
    case .warnings: return step.warnings
    case .redFlags: return step.errorCriteria
    }
  }
}

extension ProcedureStepResponse {
  var populatedInsightCategories: [InsightCategory] {
    InsightCategory.allCases.filter { !$0.items(for: self).isEmpty }
  }
}

struct RayBanHUDInsightsChip: View {
  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "lightbulb.fill")
        .font(.system(size: 9, weight: .bold))
      Text("INSIGHTS AVAILABLE")
        .font(.inter(.bold, size: 10))
        .tracking(1.0)
    }
    .foregroundStyle(Color.black.opacity(0.85))
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(
      Capsule()
        .fill(Color(red: 1.0, green: 0.76, blue: 0.11))
    )
  }
}

struct RayBanHUDStepCard: View {
  let mode: RayBanHUDStepCardMode

  @State private var selectedInsightCategory: InsightCategory?

  var body: some View {
    cardSurface
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(RayBanHUDLayoutTokens.contentPadding)
      .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
      .contentShape(RoundedRectangle(cornerRadius: RayBanHUDLayoutTokens.cardRadius, style: .continuous))
      .onChange(of: stepIdentityKey) { _, _ in
        selectedInsightCategory = nil
      }
  }

  @ViewBuilder
  private var cardSurface: some View {
    switch mode {
    case .content(let stepIndex, let stepCount, let step, let isExpanded):
      contentSurface(
        stepIndex: stepIndex,
        stepCount: stepCount,
        step: step,
        isExpanded: isExpanded
      )

    case .loading:
      VStack {
        Spacer(minLength: 0)
        ProgressView()
          .tint(Color.white.opacity(0.94))
          .controlSize(.large)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity)
    }
  }

  @ViewBuilder
  private func contentSurface(
    stepIndex: Int,
    stepCount: Int,
    step: ProcedureStepResponse?,
    isExpanded: Bool
  ) -> some View {
    let inner = VStack(alignment: .leading, spacing: isExpanded ? 10 : 2) {
      HStack(spacing: 8) {
        Text("STEP \(stepIndex) OF \(stepCount)")
          .font(.inter(.medium, size: 12))
          .tracking(1.2)
          .foregroundStyle(Color.white.opacity(0.9))

        if let step, step.hasAnyInsights, !isExpanded {
          RayBanHUDInsightsChip()
        }

        Spacer(minLength: 0)
      }

      if let step {
        Text(step.title)
          .font(.inter(.bold, size: 20))
          .foregroundStyle(Color.white.opacity(0.98))
          .fixedSize(horizontal: false, vertical: true)

        descriptionText(for: step, isExpanded: isExpanded)

        if isExpanded, step.hasAnyInsights {
          insightsSection(for: step)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)

    inner
  }

  @ViewBuilder
  private func descriptionText(for step: ProcedureStepResponse, isExpanded: Bool) -> some View {
    if isExpanded {
      Text(step.description)
        .font(.inter(.medium, size: 18))
        .foregroundStyle(Color.white.opacity(0.96))
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      compactDescription(step.description)
        .foregroundStyle(Color.white.opacity(0.96))
        .lineSpacing(2)
        .lineLimit(2)
        .truncationMode(.tail)
    }
  }

  private func compactDescription(_ description: String) -> Text {
    let limit = RayBanHUDLayoutTokens.stepDescriptionCharacterLimit
    guard description.count > limit else {
      return Text(description)
    }
    let cutoff = max(0, limit - 12)
    let prefixRaw = String(description.prefix(cutoff))
    let prefix: String
    if let space = prefixRaw.lastIndex(of: " ") {
      prefix = String(prefixRaw[..<space])
    } else {
      prefix = prefixRaw
    }
    return Text(prefix)
      .font(.inter(.medium, size: 18))
      + Text("… ")
      .font(.inter(.medium, size: 18, italic: true))
      + Text("Read more")
      .font(.inter(.bold, size: 18, italic: true))
  }

  @ViewBuilder
  private func insightsSection(for step: ProcedureStepResponse) -> some View {
    let categories = step.populatedInsightCategories
    let active = selectedInsightCategory ?? categories.first

    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "lightbulb.fill")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.11))
        Text("INSIGHTS")
          .font(.inter(.bold, size: 11))
          .tracking(1.2)
          .foregroundStyle(Color.white.opacity(0.85))
      }

      if categories.count >= 2 {
        insightsTabs(categories: categories, active: active)
      } else if let single = categories.first {
        Text(single.displayName)
          .font(.inter(.bold, size: 14))
          .foregroundStyle(Color.white.opacity(0.94))
      }

      if let active {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(active.items(for: step).enumerated()), id: \.offset) { _, item in
            HStack(alignment: .top, spacing: 6) {
              Text("•")
                .font(.inter(.medium, size: 14))
                .foregroundStyle(Color.white.opacity(0.9))
              Text(item)
                .font(.inter(.medium, size: 14))
                .foregroundStyle(Color.white.opacity(0.96))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
    }
    .padding(.top, 4)
  }

  @ViewBuilder
  private func insightsTabs(categories: [InsightCategory], active: InsightCategory?) -> some View {
    HStack(spacing: 6) {
      ForEach(categories, id: \.self) { category in
        let isActive = category == active
        Text(category.displayName)
          .font(.inter(.medium, size: 13))
          .foregroundStyle(isActive ? Color.black.opacity(0.9) : Color.white.opacity(0.92))
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(
            Capsule().fill(isActive ? Color.white.opacity(0.95) : Color.white.opacity(0.08))
          )
          .hoverSelectable(.insightsTab(category), shape: .capsule) {
            selectedInsightCategory = category
          }
      }
      Spacer(minLength: 0)
    }
  }

  private var stepIdentityKey: Int {
    switch mode {
    case .content(let stepIndex, _, _, _):
      return stepIndex
    case .loading(let stepIndex, _):
      return stepIndex ?? -1
    }
  }
}

/// The expanded reference-clip surface on the Coaching step page.
///
/// Owns the `AVPlayer` so the surrounding focus engine can toggle
/// playback via the registered `.hoverSelectable` confirm closure —
/// pinch-select and touch tap both route through `togglePlayback`.
/// The play overlay is visible when `player == nil` OR `isPlaying ==
/// false`, giving the user a clear "select to resume" affordance while
/// paused.
///
/// When `clipURL` flips to a different value (e.g., the step
/// advances), the player is torn down so the next expansion gets a
/// fresh AVPlayer at position 0 — no audio leaking from a prior step.
///
/// Photo references are not yet a server feature; if a future caller
/// passes a non-video URL, `togglePlayback` is a no-op and the panel
/// will need a media-type-aware sub-view (see plan).
struct RayBanHUDDetailPanel: View {
  let clipURL: URL?

  @State private var player: AVPlayer?
  @State private var isPlaying: Bool = false

  var body: some View {
    Group {
      if let clipURL {
        clipView(url: clipURL)
      } else {
        noClipPlaceholder
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: RayBanHUDLayoutTokens.detailHeight)
    .clipShape(
      RoundedRectangle(cornerRadius: RayBanHUDLayoutTokens.cardRadius, style: .continuous)
    )
    .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
    .hoverSelectable(
      .referenceClip,
      shape: .rounded(RayBanHUDLayoutTokens.cardRadius),
      onConfirm: togglePlayback
    )
    // Fresh player whenever the underlying URL changes — step advance,
    // step retreat, or any other case where the parent passes a new
    // clip. SwiftUI keeps the same panel instance across these changes,
    // so we have to clear state explicitly.
    .onChange(of: clipURL) { _, _ in
      player?.pause()
      player = nil
      isPlaying = false
    }
  }

  @ViewBuilder
  private func clipView(url: URL) -> some View {
    ZStack {
      if let player {
        VideoPlayer(player: player)
      } else {
        VideoThumbnailView(url: url)
      }

      if !isPlaying {
        Image(systemName: "play.circle.fill")
          .font(.system(size: 42, weight: .regular))
          .foregroundStyle(Color.white.opacity(0.92))
          .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
          .allowsHitTesting(false)
      }
    }
  }

  private var noClipPlaceholder: some View {
    ZStack {
      Color.black.opacity(0.28)

      VStack(spacing: 6) {
        Image(systemName: "rectangle.slash")
          .font(.system(size: 22, weight: .medium))
          .foregroundStyle(Color.white.opacity(0.78))
          .padding(.bottom, 4)

        Text("No reference")
          .font(.inter(.bold, size: 16))
          .foregroundStyle(Color.white.opacity(0.82))

        Text("This step is instructional only.")
          .font(.inter(.medium, size: 12))
          .foregroundStyle(Color.white.opacity(0.62))
      }
      .multilineTextAlignment(.center)
      .padding(RayBanHUDLayoutTokens.contentPadding)
    }
  }

  /// Toggle play/pause. First select on a fresh panel constructs the
  /// AVPlayer and starts playback. Subsequent selects flip between
  /// play and pause. No-op when there's no clip URL (placeholder
  /// state) or when a non-video URL is passed (forward-looking guard
  /// — currently not exercised since the server only emits MP4s).
  private func togglePlayback() {
    guard let url = clipURL else { return }
    if player == nil {
      let p = AVPlayer(url: url)
      player = p
      p.play()
      isPlaying = true
      return
    }
    if isPlaying {
      player?.pause()
    } else {
      player?.play()
    }
    isPlaying.toggle()
  }
}

struct RayBanHUDCompletionSummaryCard: View {
  let onConfirm: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 60, weight: .regular))
        .foregroundStyle(completionGradient)
        .frame(height: 64)

      Text("You’re all done. Great job!")
        .font(.inter(.bold, size: 16))
        .foregroundStyle(Color.white.opacity(0.98))
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .frame(height: RayBanHUDLayoutTokens.completionHeight)
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
    .hoverSelectable(.completionOk, shape: .rounded(RayBanHUDLayoutTokens.cardRadius), onConfirm: onConfirm)
  }

  private var completionGradient: RadialGradient {
    RadialGradient(
      stops: [
        .init(color: Color(red: 170.0 / 255.0, green: 233.0 / 255.0, blue: 169.0 / 255.0), location: 0.24),
        .init(color: Color(red: 110.0 / 255.0, green: 189.0 / 255.0, blue: 132.0 / 255.0), location: 0.52),
        .init(color: Color(red: 96.0 / 255.0, green: 149.0 / 255.0, blue: 144.0 / 255.0), location: 1.0),
      ],
      center: .center,
      startRadius: 4,
      endRadius: 60
    )
  }
}

struct RayBanHUDCompletionActionCard: View {
  let icon: String
  let label: String
  let id: HUDControl
  let onConfirm: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 18, weight: .medium))
        .frame(width: RayBanHUDLayoutTokens.iconFrame, height: RayBanHUDLayoutTokens.iconFrame)

      Text(label)
        .font(.inter(.medium, size: 14))

      Spacer(minLength: 0)
    }
    .foregroundStyle(Color.white.opacity(0.98))
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity)
    .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.completionActionRadius))
    .hoverSelectable(
      id,
      shape: .rounded(RayBanHUDLayoutTokens.completionActionRadius),
      onConfirm: onConfirm
    )
  }
}

