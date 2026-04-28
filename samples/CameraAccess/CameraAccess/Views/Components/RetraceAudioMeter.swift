import SwiftUI

/// Subtle multi-bar audio amplitude indicator. Replaces the old 3-bar
/// `ExpertHUDAudioMeter` and the Bool-driven `SoundWaveView`.
///
/// Drives off a single pre-smoothed `peak: Float` (0...1) and renders a
/// rolling window of recent peaks as vertical bars. Peaks visually
/// "travel" rightward — newest sample on the right, oldest on the left —
/// which gives the GIF-reference flowing-wave feel without any fake phase
/// oscillators.
///
/// Idle behavior: at sustained `peak ≈ 0` the buffer drains to zero and
/// bars settle at the configured min height. The whole meter dims to 35%
/// opacity at silence and ramps to 100% at full volume so it stays
/// visually subtle during quiet moments.
struct RetraceAudioMeter: View {
  /// Pre-smoothed peak amplitude of the *AI's* voice output, `0...1`.
  /// Drives the speaking palette + bar heights when AI is speaking.
  let aiPeak: Float

  /// Pre-smoothed peak amplitude of the *user's* mic input, `0...1`.
  /// When AI is silent and this rises above `listeningThreshold`, the
  /// meter switches to the white "listening" state and drives bar
  /// heights from this value instead of `aiPeak`. Pass 0 if the call
  /// site has no mic signal (e.g. expert recording's controls bar).
  let userPeak: Float

  /// Single tint applied uniformly to every bar.
  let tint: Color

  /// Two presets: `.compact` for the in-lens HUD chip, `.standard` for
  /// the controls bar. Drives bar count, dimensions, and frame size.
  let intensity: Intensity

  /// New two-peak initializer. AI-only call sites can pass `userPeak: 0`.
  init(aiPeak: Float, userPeak: Float = 0, tint: Color = .white, intensity: Intensity = .compact) {
    self.aiPeak = aiPeak
    self.userPeak = userPeak
    self.tint = tint
    self.intensity = intensity
  }

  /// Backward-compatible single-peak initializer. Treats the value as
  /// the AI peak — preserves prior speaking-palette behavior for any
  /// call site that hasn't migrated to the two-peak form yet.
  init(peak: Float, tint: Color = .white, intensity: Intensity = .compact) {
    self.aiPeak = peak
    self.userPeak = 0
    self.tint = tint
    self.intensity = intensity
  }

  /// Threshold at which the AI peak is considered "speaking" — the
  /// smoothed mirror in the VM stays above ~0.04 during continuous
  /// playback and drops near 0 between turns. Sits comfortably above
  /// the noise floor.
  private let aiSpeakingThreshold: Float = 0.05
  /// Threshold at which the user mic is considered "actively talking".
  /// Slightly higher than the AI threshold because mic input has a
  /// non-zero noise floor even at silence.
  private let listeningThreshold: Float = 0.07

  /// Derived display state. Computed at render time from the two peaks.
  /// `.aiSpeaking` always wins over `.listening` so back-channels from
  /// the user during AI playback don't flicker the palette.
  private enum DisplayMode { case aiSpeaking, listening, idle }
  private var displayMode: DisplayMode {
    if aiPeak > aiSpeakingThreshold { return .aiSpeaking }
    if userPeak > listeningThreshold { return .listening }
    return .idle
  }

  /// The peak that drives bar heights / loudness — picks AI in speaking
  /// mode, mic in listening mode, the larger of the two at idle so a
  /// quiet whisper still nudges the meter.
  private var drivingPeak: Float {
    switch displayMode {
    case .aiSpeaking: return aiPeak
    case .listening: return userPeak
    case .idle: return max(aiPeak, userPeak)
    }
  }

  /// History of recent peaks, length = `intensity.barCount`. Index 0 is
  /// the **newest** sample (leftmost bar). Each tick we insert at the
  /// front and drop the last so peaks visually flow left → right.
  @State private var buffer: [Float] = []
  /// Last sample-tick time. Throttles the rolling buffer to 14 Hz even
  /// though the host `TimelineView` redraws faster (so the per-bar
  /// wobble stays smooth).
  @State private var lastSampledAt: Date = .distantPast
  /// EMA of the buffer mean, in `0...1`. Drives the whole-meter opacity
  /// ramp + scales the per-bar wobble so silence still resolves flat.
  @State private var loudnessSmoothed: Float = 0

  /// Buffer-rotation interval — 14 Hz keeps each bar transition
  /// perceptible without flickering.
  private let sampleInterval: TimeInterval = 0.07
  /// `TimelineView` redraw interval — 30 Hz so the per-bar wobble is
  /// smooth even though the buffer only rotates at 14 Hz.
  private let renderInterval: TimeInterval = 0.033

  var body: some View {
    TimelineView(.animation(minimumInterval: renderInterval, paused: false)) { context in
      meter(at: context.date)
        .frame(width: intensity.frameWidth, height: intensity.frameHeight)
        .opacity(meterOpacity)
        .onChange(of: context.date) { _, newDate in
          tickIfDue(at: newDate)
        }
        .onAppear {
          if buffer.isEmpty {
            buffer = Array(repeating: 0, count: intensity.barCount)
          }
        }
    }
  }

  private func meter(at now: Date) -> some View {
    HStack(alignment: .bottom, spacing: intensity.barSpacing) {
      ForEach(0..<intensity.barCount, id: \.self) { i in
        RoundedRectangle(cornerRadius: intensity.cornerRadius, style: .continuous)
          .fill(barColor(at: i))
          .frame(
            width: intensity.barWidth,
            height: barHeight(for: sample(at: i), index: i, time: now.timeIntervalSinceReferenceDate)
          )
      }
    }
    .frame(height: intensity.frameHeight, alignment: .bottom)
    .scaleEffect(meterScale, anchor: .bottom)
    .animation(.easeOut(duration: 0.06), value: buffer)
  }

  /// Per-bar color. AI-speaking → pastel sky→rose gradient; listening →
  /// uniform white (signals "mic is hearing you"); idle → pastel at the
  /// silence floor.
  private func barColor(at index: Int) -> Color {
    if displayMode == .listening {
      return Color.white
    }
    let palette = Self.pastelPalette
    let frac = Double(index) / Double(max(1, intensity.barCount - 1))
    let scaled = frac * Double(palette.count - 1)
    let lo = Int(scaled.rounded(.down))
    let hi = min(palette.count - 1, lo + 1)
    let t = scaled - Double(lo)
    let pastel = palette[lo].lerp(to: palette[hi], t: t)
    let white = RGB(r: 1, g: 1, b: 1)
    // Floor at 0.85 so the saturated palette dominates over the white
    // baseline even at silence — without this the meter reads as
    // pale-tinted-white when quiet, and the lens's additive-blend mode
    // wipes the remaining hue character out entirely.
    let strength = 0.85 + 0.15 * Double(loudnessSmoothed.clamped(to: 0...1))
    return white.lerp(to: pastel, t: strength).color(opacity: 1)
  }

  /// Scale-up tied to the smoothed loudness so the whole meter breathes
  /// with the speaker. Up to ~12% at peak — visible without feeling
  /// like the meter is jumping out of its frame.
  private var meterScale: CGFloat {
    1.0 + 0.12 * CGFloat(loudnessSmoothed.clamped(to: 0...1))
  }

  /// Saturated palette — sky → cyan → mint → peach → rose. Each color
  /// keeps at least one channel low so the hue survives the lens's
  /// optional `.plusLighter` additive blend (Meta Ray-Ban Display
  /// simulation, `RayBanHUDEmulator.swift:150`). With pastels the R/G/B
  /// channels are all already bright and additive composition clamps
  /// every bar to white; saturated tones preserve their dominant
  /// wavelength under both `.normal` and `.plusLighter` blends.
  private static let pastelPalette: [RGB] = [
    RGB(r: 0.18, g: 0.55, b: 1.00),  // sky blue
    RGB(r: 0.20, g: 0.92, b: 0.95),  // cyan
    RGB(r: 0.42, g: 0.98, b: 0.55),  // mint green
    RGB(r: 1.00, g: 0.74, b: 0.30),  // amber
    RGB(r: 1.00, g: 0.45, b: 0.72),  // pink
  ]

  // MARK: - Sampling

  private func tickIfDue(at now: Date) {
    guard now.timeIntervalSince(lastSampledAt) >= sampleInterval else { return }
    lastSampledAt = now

    var next = buffer
    if next.count != intensity.barCount {
      next = Array(repeating: 0, count: intensity.barCount)
    }
    if !next.isEmpty {
      // Newest peak at index 0, oldest peeled off the end → flow L → R.
      next.removeLast()
      next.insert(drivingPeak.clamped(to: 0...1), at: 0)
    }
    buffer = next

    // EMA over the buffer mean — drives the global opacity ramp + the
    // wobble amplitude. Silence → 0 → both fall to baseline.
    let mean = next.reduce(0, +) / Float(max(1, next.count))
    loudnessSmoothed += 0.2 * (mean - loudnessSmoothed)
  }

  private func sample(at index: Int) -> Float {
    guard index < buffer.count else { return 0 }
    return buffer[index]
  }

  // MARK: - Rendering

  /// Bar height = base (from sample) + per-bar sine wobble scaled by
  /// smoothed loudness. The wobble is what makes the meter feel alive
  /// without mapping the amplitude literally — neighbors run out of
  /// phase, so the wave appears to undulate organically. At silence,
  /// `loudnessSmoothed → 0` zeros the wobble and bars settle flat.
  private func barHeight(for sample: Float, index: Int, time: TimeInterval) -> CGFloat {
    let baseFrac = intensity.minFraction
      + sample * (intensity.maxFraction - intensity.minFraction)

    let phase = time * Self.wobbleFrequency + Double(index) * Self.wobblePhasePerBar
    let wobble = Float(sin(phase)) * loudnessSmoothed * Self.wobbleAmplitude

    let frac = (baseFrac + wobble).clamped(to: intensity.minFraction...intensity.maxFraction)
    return intensity.frameHeight * CGFloat(frac)
  }

  private var meterOpacity: Double {
    // Floor at 0.65 so the colored bars stay legible at silence —
    // dimmer than that and the gradient washes out, especially under
    // the lens's additive-blend mode where low-alpha colors collapse
    // toward the camera background.
    Double(0.65 + 0.35 * loudnessSmoothed.clamped(to: 0...1))
  }

  /// Radians per second for the wobble carrier. ~6 rad/s ≈ ~1 Hz —
  /// slow enough to feel organic, fast enough to read as motion.
  private static let wobbleFrequency: Double = 6.0
  /// Per-bar phase offset in radians. 0.7 rad ≈ 40° — neighbors are
  /// visibly out of phase so the wave undulates instead of pumping in
  /// unison.
  private static let wobblePhasePerBar: Double = 0.7
  /// Max wobble contribution to `frac`, before clamping. At 0.30 with
  /// `loudnessSmoothed = 1`, the bar varies up to ±30% of the frame
  /// height around its sample-driven base — visibly lively without
  /// looking jittery.
  private static let wobbleAmplitude: Float = 0.30
}

// MARK: - Intensity preset

extension RetraceAudioMeter {
  enum Intensity {
    case compact
    case wide
    case standard

    var barCount: Int {
      switch self {
      case .compact: return 9
      case .wide: return 27
      case .standard: return 11
      }
    }

    var barWidth: CGFloat {
      switch self {
      case .compact, .wide: return 2
      case .standard: return 2.5
      }
    }

    var barSpacing: CGFloat {
      switch self {
      case .compact, .wide: return 1.5
      case .standard: return 2
      }
    }

    var frameHeight: CGFloat {
      switch self {
      case .compact, .wide: return 12
      case .standard: return 16
      }
    }

    var minFraction: Float {
      switch self {
      case .compact, .wide: return 0.10
      case .standard: return 0.08
      }
    }

    var maxFraction: Float { 1.0 }

    var cornerRadius: CGFloat {
      switch self {
      case .compact, .wide: return 1
      case .standard: return 1.5
      }
    }

    var frameWidth: CGFloat {
      let count = CGFloat(barCount)
      return (count * barWidth) + ((count - 1) * barSpacing)
    }
  }
}

// MARK: - Helpers

private extension Float {
  func clamped(to range: ClosedRange<Float>) -> Float {
    min(range.upperBound, max(range.lowerBound, self))
  }
}

/// Plain RGB tuple so the meter can interpolate colors without depending
/// on iOS 18's `Color.mix(with:by:)` or routing through `UIColor`.
struct RGB {
  let r: Double
  let g: Double
  let b: Double

  func lerp(to other: RGB, t: Double) -> RGB {
    let clamped = max(0, min(1, t))
    return RGB(
      r: r + (other.r - r) * clamped,
      g: g + (other.g - g) * clamped,
      b: b + (other.b - b) * clamped
    )
  }

  func color(opacity: Double = 1) -> Color {
    Color(red: r, green: g, blue: b, opacity: opacity)
  }
}
