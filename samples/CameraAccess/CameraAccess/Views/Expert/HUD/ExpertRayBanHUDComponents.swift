import SwiftUI

// MARK: - Recording status chip (top-center)

/// Red-dot + MM:SS + 3-bar audio meter. Always visible while recording.
struct ExpertHUDRecordingStatusChip: View {
  let duration: TimeInterval
  let audioPeak: Float
  let isRecording: Bool

  var body: some View {
    HStack(spacing: 10) {
      ExpertHUDRecordingDot(isActive: isRecording)

      Text(formattedDuration)
        .font(.inter(.bold, size: 16))
        .foregroundStyle(Color.white.opacity(0.98))
        .monospacedDigit()

      ExpertHUDAudioMeter(peak: audioPeak)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .rayBanHUDPanel(shape: .capsule)
  }

  private var formattedDuration: String {
    let mins = Int(duration) / 60
    let secs = Int(duration) % 60
    return String(format: "%02d:%02d", mins, secs)
  }
}

/// Pulsing red dot. Kept as its own view so the pulse animation doesn't
/// re-run every time the chip's timer text updates.
private struct ExpertHUDRecordingDot: View {
  let isActive: Bool
  @State private var pulse = false

  var body: some View {
    Circle()
      .fill(Color(red: 0.96, green: 0.26, blue: 0.21))
      .frame(width: 10, height: 10)
      .opacity(pulse ? 0.5 : 1.0)
      .shadow(color: Color(red: 0.96, green: 0.26, blue: 0.21).opacity(0.6), radius: 4)
      .onAppear {
        guard isActive else { return }
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
          pulse.toggle()
        }
      }
  }
}

/// 3-bar audio meter. `peak` is 0...1 (smoothed by the view model).
struct ExpertHUDAudioMeter: View {
  let peak: Float

  private let barCount = 3
  private let thresholds: [Float] = [0.08, 0.24, 0.55]

  var body: some View {
    HStack(alignment: .bottom, spacing: 3) {
      ForEach(0..<barCount, id: \.self) { index in
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(barColor(index: index))
          .frame(width: 3, height: barHeight(index: index))
      }
    }
    .frame(height: 14, alignment: .bottom)
    .animation(.easeOut(duration: 0.08), value: peak)
  }

  private func barHeight(index: Int) -> CGFloat {
    let base: CGFloat = 5
    let growth: CGFloat = 4.5
    return base + growth * CGFloat(index)
  }

  private func barColor(index: Int) -> Color {
    guard peak >= thresholds[index] else {
      return Color.white.opacity(0.20)
    }
    return Color.white.opacity(0.95)
  }
}

// MARK: - Mic source badge (top-trailing)

struct ExpertHUDMicSourceBadge: View {
  let micSource: ExpertHUDMicSource

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: micSource.iconName)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.94))

      Text(micSource.label)
        .font(.inter(.medium, size: 12))
        .tracking(0.4)
        .foregroundStyle(Color.white.opacity(0.92))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .rayBanHUDPanel(shape: .capsule)
  }
}

// MARK: - Stop-recording pill (hover-to-confirm)

/// Mirrors `RayBanHUDExitPill` — a capsule that requires a 2-second hold to
/// commit. Reuses the shared `HUDHoverCoordinator` via `.hoverSelectable`.
struct ExpertHUDStopPill: View {
  let isSelected: () -> Bool
  let onHoldStart: () -> Void
  let onHoldEnd: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "stop.circle.fill")
        .font(.system(size: 20, weight: .medium))
        .frame(
          width: RayBanHUDLayoutTokens.iconFrame,
          height: RayBanHUDLayoutTokens.iconFrame
        )

      Text("Stop recording")
        .font(.inter(.medium, size: 14))
        .lineLimit(1)
    }
    .foregroundStyle(Color.white.opacity(0.98))
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, 10)
    .rayBanHUDPanel(shape: .capsule)
    .hoverSelectable(.expertStopRecording, shape: .capsule, behavior: .selectOnly) {}
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          guard isSelected() else { return }
          onHoldStart()
        }
        .onEnded { _ in
          onHoldEnd()
        }
    )
  }
}

/// Hold-countdown overlay shown while the user is holding the stop pill.
/// Cloned from `RayBanHUDExitOverlay` with different copy.
struct ExpertHUDStopOverlay: View {
  let progress: CGFloat
  let onCancel: () -> Void

  var body: some View {
    VStack {
      Spacer(minLength: 0)

      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text("Stop recording")
            .font(.inter(.bold, size: 20))
            .foregroundStyle(Color.white.opacity(0.98))

          Spacer(minLength: 0)

          Text("\(remainingSeconds) sec left")
            .font(.inter(.medium, size: 12))
            .foregroundStyle(Color.white.opacity(0.92))
        }

        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule()
              .fill(Color.black.opacity(0.35))

            Capsule()
              .fill(Color(red: 0.96, green: 0.26, blue: 0.21))
              .frame(width: geometry.size.width * clampedProgress)
          }
        }
        .frame(height: 5)
      }
      .padding(RayBanHUDLayoutTokens.contentPadding)
      .frame(maxWidth: .infinity)
      .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
      .contentShape(
        RoundedRectangle(cornerRadius: RayBanHUDLayoutTokens.cardRadius, style: .continuous)
      )
      .onTapGesture(perform: onCancel)

      Spacer(minLength: 0)
    }
  }

  private var clampedProgress: CGFloat { max(0, min(progress, 1)) }

  private var remainingSeconds: Int {
    let remaining = max(
      0,
      RayBanHUDLayoutTokens.exitHoldDuration
        - (RayBanHUDLayoutTokens.exitHoldDuration * Double(clampedProgress))
    )
    return Int(ceil(remaining))
  }
}

// MARK: - Narration tip card

/// Primary bottom-cluster card. Rotates through static tips automatically
/// and responds to horizontal swipes. Same minimum-distance / commit-threshold
/// tokens as the learner step card so the gesture feel is identical.
struct ExpertHUDNarrationTipCard: View {
  let tip: ExpertNarrationTip
  let horizontalOffset: CGFloat
  let onDragChanged: (DragGesture.Value) -> Void
  let onDragEnded: (DragGesture.Value) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("HOW TO NARRATE")
        .font(.inter(.medium, size: 12))
        .tracking(1.2)
        .foregroundStyle(Color.white.opacity(0.9))

      Text(tip.title)
        .font(.inter(.bold, size: 20))
        .foregroundStyle(Color.white.opacity(0.98))
        .fixedSize(horizontal: false, vertical: true)

      Text(tip.body)
        .font(.inter(.medium, size: 14))
        .foregroundStyle(Color.white.opacity(0.96))
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(RayBanHUDLayoutTokens.contentPadding)
    .frame(minHeight: RayBanHUDLayoutTokens.stepCardMinHeight, alignment: .center)
    .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
    .contentShape(
      RoundedRectangle(cornerRadius: RayBanHUDLayoutTokens.cardRadius, style: .continuous)
    )
    .offset(x: horizontalOffset)
    .simultaneousGesture(
      DragGesture(minimumDistance: RayBanHUDLayoutTokens.stepSwipeMinimumDistance)
        .onChanged { value in onDragChanged(value) }
        .onEnded { value in onDragEnded(value) }
    )
  }
}

// MARK: - Rolling transcript card

/// 3-line rolling transcript. Latest line at bottom, full opacity; older
/// lines fade. Fixed height so long lines don't reflow the cluster.
struct ExpertHUDRollingTranscriptCard: View {
  let segments: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("YOU'RE SAYING")
        .font(.inter(.medium, size: 11))
        .tracking(1.2)
        .foregroundStyle(Color.white.opacity(0.8))

      VStack(alignment: .leading, spacing: 2) {
        ForEach(displayed.indices, id: \.self) { index in
          Text(displayed[index])
            .font(.inter(.medium, size: 14))
            .foregroundStyle(Color.white.opacity(opacity(forIndex: index)))
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: 92)
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, 12)
    .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
  }

  /// Three slots, top-to-bottom. Older entries padded with empty strings so
  /// the card never collapses vertically.
  private var displayed: [String] {
    let capped = segments.suffix(3)
    let padded = Array(repeating: "", count: max(0, 3 - capped.count)) + Array(capped)
    return padded
  }

  private func opacity(forIndex index: Int) -> Double {
    // index 0 is top (oldest), index 2 is bottom (newest).
    switch index {
    case 0: return 0.40
    case 1: return 0.72
    default: return 1.0
    }
  }
}
