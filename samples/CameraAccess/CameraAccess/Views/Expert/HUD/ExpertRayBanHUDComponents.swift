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

      RetraceAudioMeter(peak: audioPeak, tint: .white, intensity: .compact)
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

// MARK: - Stop-recording pill

/// Full-width stop-recording pill anchored at the bottom of the lens.
/// **Two-stage commit on touch**: first tap highlights (cursor lands);
/// second tap (while highlighted) opens the confirmation overlay. The
/// overlay then carries a 3-second auto-confirm countdown with an X
/// to cancel — three layers of protection against accidental stops.
/// Pinch users get the same flow for free: pinch-drag lands the
/// cursor, pinch-select fires `onTrigger`.
struct ExpertHUDStopPill: View {
  let onTrigger: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "stop.circle.fill")
        .font(.system(size: 18, weight: .medium))

      Text("Stop recording")
        .font(.inter(.medium, size: 14))
        .lineLimit(1)
    }
    .foregroundStyle(Color.white.opacity(0.98))
    .frame(maxWidth: .infinity)
    .padding(.vertical, 9)
    .rayBanHUDPanel(shape: .capsule)
    .hoverSelectable(.expertStopRecording, shape: .capsule, behavior: .confirmOnSecondTap) {
      onTrigger()
    }
  }
}

/// Auto-confirm overlay shown after the user triggers stop on the
/// Expert HUD. Layered on top of the (recessed) page content via the
/// recede-and-arrive pattern — see `DESIGN.md`. Counts down for
/// `duration` seconds; if the user taps the X (or pinch-back / pinch-
/// selects the X via the focus engine) before the timer expires,
/// `onCancel` fires and recording continues. Otherwise the timer
/// auto-fires `onConfirm`.
///
/// The auto-confirm is owned by the parent page (it schedules the
/// commit Task and clears it on cancel) — this view only renders the
/// progress bar + cancel affordance.
struct ExpertHUDStopOverlay: View {
  let startedAt: Date
  let duration: TimeInterval
  let onCancel: () -> Void

  @State private var fillProgress: CGFloat = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color.black.opacity(0.35))

          Capsule()
            .fill(Color(red: 0.96, green: 0.26, blue: 0.21))
            .frame(width: geometry.size.width * fillProgress)
        }
      }
      .frame(height: 5)
    }
    .padding(RayBanHUDLayoutTokens.contentPadding)
    .frame(maxWidth: 280)
    // Standard panel surface — the recede recipe on the underlying
    // page (scale 0.92, opacity 0.32, blur 6) is what makes the
    // overlay read as foreground.
    .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
    .onAppear {
      withAnimation(.linear(duration: duration)) {
        fillProgress = 1
      }
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text("Stop recording")
        .font(.inter(.bold, size: 18))
        .foregroundStyle(Color.white.opacity(0.98))

      Spacer(minLength: 0)

      TimelineView(.animation(minimumInterval: 0.25)) { context in
        Text("\(remainingSeconds(at: context.date)) sec")
          .font(.inter(.medium, size: 12))
          .foregroundStyle(Color.white.opacity(0.92))
          .monospacedDigit()
      }

      cancelButton
    }
  }

  private var cancelButton: some View {
    Image(systemName: "xmark")
      .font(.system(size: 13, weight: .bold))
      .foregroundStyle(Color.white.opacity(0.92))
      .frame(width: 28, height: 28)
      .background(
        Circle().fill(Color.white.opacity(0.12))
      )
      .contentShape(Circle())
      // `.tapToFire` so a touch tap cancels in one motion. Pinch users
      // get the same path via the focus engine — the overlay handler
      // default-focuses this control.
      .hoverSelectable(.expertStopCancel, shape: .capsule, behavior: .tapToFire) {
        onCancel()
      }
  }

  private func remainingSeconds(at now: Date) -> Int {
    let elapsed = now.timeIntervalSince(startedAt)
    return max(0, Int(ceil(duration - elapsed)))
  }
}

// MARK: - Narration tip card

/// Primary lens card. Pure presentational view of one tip — fixed
/// height regardless of content length so neighbouring carousel cards
/// don't pop up/down as the user pages through. The carousel mechanics
/// (offset / drag / commit animation) live in `ExpertNarrationTipPage`,
/// not here.
///
/// Title + body are line-limited so the card height stays constant —
/// long copy truncates instead of growing the card. Picking the tip
/// pool wisely matters more than allowing variable height (per the
/// design system: card sizes don't reflow during a session).
struct ExpertHUDNarrationTipCard: View {
  let tip: ExpertNarrationTip

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("HOW TO NARRATE")
        .font(.inter(.medium, size: 12))
        .tracking(1.2)
        .foregroundStyle(Color.white.opacity(0.9))

      Text(tip.title)
        .font(.inter(.bold, size: 20))
        .foregroundStyle(Color.white.opacity(0.98))
        .lineLimit(2)
        .truncationMode(.tail)

      Text(tip.body)
        .font(.inter(.medium, size: 14))
        .foregroundStyle(Color.white.opacity(0.96))
        .lineSpacing(2)
        .lineLimit(3)
        .truncationMode(.tail)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(RayBanHUDLayoutTokens.contentPadding)
    // Fill whatever vertical space the parent carousel hands us — the
    // card is the visual focal point of the Expert lens, so claiming
    // the room between the timer pill and stop pill is the right
    // default. Text content stays centered inside the panel.
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
    .contentShape(
      RoundedRectangle(cornerRadius: RayBanHUDLayoutTokens.cardRadius, style: .continuous)
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
