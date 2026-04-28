import SwiftUI

enum HUDSurfaceShape: Equatable {
  case capsule
  case rounded(CGFloat)
}

enum HUDAdditiveSurfaceVariant: Hashable {
  /// Existing additive panel recipe. Coaching uses this default and should
  /// keep its verified-good visual output.
  case standard
  /// Lower-tint additive recipe for live-preview hosts where SwiftUI can show
  /// the pre-blended dark surface before the plus-lighter composite resolves.
  case lowTint
}

/// Environment-propagated flag that tells lens components which compositing
/// mode the parent emulator is rendering under (`.plusLighter` additive vs.
/// `.normal` opaque). Threaded from `RayBanHUDEmulator` so the panel surface
/// can swap to a dark "container" recipe when additive — bright surfaces
/// halate the camera background and bleed white text edges; dark surfaces
/// composite to ~transparent under additive and give bright content a
/// clean, low-luminance neighborhood. Reference: Google's
/// "transparent screens" guidance (design.google/library/transparent-screens).
private struct HUDAdditiveBlendKey: EnvironmentKey {
  static let defaultValue: Bool = false
}

private struct HUDAdditiveSurfaceVariantKey: EnvironmentKey {
  static let defaultValue: HUDAdditiveSurfaceVariant = .standard
}

extension EnvironmentValues {
  var hudAdditiveBlend: Bool {
    get { self[HUDAdditiveBlendKey.self] }
    set { self[HUDAdditiveBlendKey.self] = newValue }
  }

  var hudAdditiveSurfaceVariant: HUDAdditiveSurfaceVariant {
    get { self[HUDAdditiveSurfaceVariantKey.self] }
    set { self[HUDAdditiveSurfaceVariantKey.self] = newValue }
  }
}

struct RayBanHUDPanelModifier: ViewModifier {
  let shape: HUDSurfaceShape
  @Environment(\.hudAdditiveBlend) private var additiveBlend
  @Environment(\.hudAdditiveSurfaceVariant) private var additiveSurfaceVariant

  func body(content: Content) -> some View {
    content
      .background {
        HUDSurfaceBackground(shape: shape)
      }
      .shadow(color: Color.black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowY)
  }

  private var usesLowTintAdditiveSurface: Bool {
    additiveBlend && additiveSurfaceVariant == .lowTint
  }

  private var shadowOpacity: Double {
    usesLowTintAdditiveSurface ? 0 : 0.22
  }

  private var shadowRadius: CGFloat {
    usesLowTintAdditiveSurface ? 0 : 18
  }

  private var shadowY: CGFloat {
    usesLowTintAdditiveSurface ? 0 : 10
  }
}

extension View {
  func rayBanHUDPanel(shape: HUDSurfaceShape) -> some View {
    modifier(RayBanHUDPanelModifier(shape: shape))
  }
}

struct HUDSurfaceBackground: View {
  let shape: HUDSurfaceShape
  @Environment(\.hudAdditiveBlend) private var additiveBlend
  @Environment(\.hudAdditiveSurfaceVariant) private var additiveSurfaceVariant

  var body: some View {
    ZStack {
      fill
      diagonalShade
      // Sheen is pure halation under `.plusLighter` — drop it in additive.
      if !additiveBlend {
        sheen
      }
      stroke
    }
    .compositingGroup()
  }

  @ViewBuilder
  private var fill: some View {
    switch shape {
    case .capsule:
      Capsule()
        .fill(surfaceBase)
    case .rounded(let radius):
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(surfaceBase)
    }
  }

  @ViewBuilder
  private var diagonalShade: some View {
    switch shape {
    case .capsule:
      Capsule()
        .fill(surfaceShade)
    case .rounded(let radius):
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(surfaceShade)
    }
  }

  @ViewBuilder
  private var sheen: some View {
    switch shape {
    case .capsule:
      Capsule()
        .fill(surfaceSheen)
    case .rounded(let radius):
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(surfaceSheen)
    }
  }

  @ViewBuilder
  private var stroke: some View {
    switch shape {
    case .capsule:
      Capsule()
        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
    case .rounded(let radius):
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
    }
  }

  private var surfaceBase: LinearGradient {
    if additiveBlend {
      if additiveSurfaceVariant == .lowTint {
        // Expert and Troubleshoot sit directly over live AVCapture preview.
        // Keep the dark container effectively transparent there; the white
        // content, stroke, and hover fills still add light under plus-lighter.
        return LinearGradient(
          colors: [
            Color(red: 0.04, green: 0.05, blue: 0.06).opacity(0.035),
            Color(red: 0.02, green: 0.02, blue: 0.03).opacity(0.025),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
      // Near-black "dark container" — under `.plusLighter` this composites
      // to ~transparent (camera passes through unchanged) and gives white
      // text a clean low-luminance neighborhood instead of the halated
      // mid-gray that bled into adjacent pixels. Keep opacity low because
      // live AVCapture preview composition can show the pre-blended dark
      // surface even when screenshots flatten the additive blend correctly.
      return LinearGradient(
        colors: [
          Color(red: 0.04, green: 0.05, blue: 0.06).opacity(0.28),
          Color(red: 0.02, green: 0.02, blue: 0.03).opacity(0.22),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
    return LinearGradient(
      colors: [
        Color(red: 0.44, green: 0.48, blue: 0.49).opacity(0.75),
        Color(red: 0.39, green: 0.43, blue: 0.44).opacity(0.75),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var surfaceShade: LinearGradient {
    if additiveBlend {
      if additiveSurfaceVariant == .lowTint {
        return LinearGradient(
          colors: [
            Color.clear,
            Color.clear,
            Color.clear,
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
      // Drop the white-ish lift under additive — those bright stops are
      // halation sources. Keep only the dark stop so the gradient stays
      // luminance-neutral on the camera.
      return LinearGradient(
        colors: [
          Color.clear,
          Color.clear,
          Color.black.opacity(0.08),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
    return LinearGradient(
      colors: [
        Color.white.opacity(0.05),
        Color.white.opacity(0.01),
        Color.black.opacity(0.12),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var surfaceSheen: RadialGradient {
    RadialGradient(
      colors: [
        Color.white.opacity(0.18),
        Color.white.opacity(0.08),
        .clear,
      ],
      center: .topTrailing,
      startRadius: 6,
      endRadius: 220
    )
  }
}

struct HUDHoverHighlight: View {
  let shape: HUDSurfaceShape
  let isVisible: Bool

  var body: some View {
    ZStack {
      fill
      stroke
    }
    .opacity(isVisible ? 1 : 0)
    .animation(.easeInOut(duration: 0.16), value: isVisible)
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private var fill: some View {
    switch shape {
    case .capsule:
      Capsule()
        .fill(fillGradient)
        .padding(-1)
    case .rounded(let radius):
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(fillGradient)
        .padding(-1)
    }
  }

  @ViewBuilder
  private var stroke: some View {
    switch shape {
    case .capsule:
      Capsule()
        .strokeBorder(strokeGradient, lineWidth: 1.5)
        .padding(-1)
        .shadow(color: Color.white.opacity(0.35), radius: 6, x: 0, y: 0)
    case .rounded(let radius):
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(strokeGradient, lineWidth: 1.5)
        .padding(-1)
        .shadow(color: Color.white.opacity(0.35), radius: 6, x: 0, y: 0)
    }
  }

  private var fillGradient: LinearGradient {
    LinearGradient(
      colors: [
        Color.white.opacity(0.14),
        Color.white.opacity(0.05),
        .clear,
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var strokeGradient: LinearGradient {
    LinearGradient(
      colors: [
        Color.white.opacity(0.95),
        Color.white.opacity(0.5),
        Color.white.opacity(0.22),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
}

/// Shared bottom-of-lens audio row used by active session HUDs.
///
/// Mute and Exit are selectable capsules; the waveform is passive status
/// only so it does not read as a control or confuse mic muting with AI
/// playback.
struct RayBanHUDBottomAudioActionRow: View {
  let isMuted: Bool
  let aiPeak: Float
  let userPeak: Float
  let meterStyle: RetraceAudioMeter.Style
  let muteControl: HUDControl
  let exitControl: HUDControl
  let onToggleMute: () -> Void
  let onExit: () -> Void

  init(
    isMuted: Bool,
    aiPeak: Float,
    userPeak: Float,
    meterStyle: RetraceAudioMeter.Style = .conversation,
    muteControl: HUDControl,
    exitControl: HUDControl,
    onToggleMute: @escaping () -> Void,
    onExit: @escaping () -> Void
  ) {
    self.isMuted = isMuted
    self.aiPeak = aiPeak
    self.userPeak = userPeak
    self.meterStyle = meterStyle
    self.muteControl = muteControl
    self.exitControl = exitControl
    self.onToggleMute = onToggleMute
    self.onExit = onExit
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      wideAudioMeter

      HStack(alignment: .bottom, spacing: 12) {
        muteCapsule

        Spacer(minLength: 0)

        exitCapsule
      }
    }
    .frame(height: 34)
  }

  private var muteCapsule: some View {
    HStack(spacing: 6) {
      Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(
          isMuted ? Color.white.opacity(0.55) : Color.white.opacity(0.95)
        )

      Text(isMuted ? "Unmute" : "Mute")
        .font(.inter(.medium, size: 13))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .layoutPriority(1)
    .rayBanHUDPanel(shape: .capsule)
    .hoverSelectable(muteControl, shape: .capsule, onConfirm: onToggleMute)
  }

  private var wideAudioMeter: some View {
    RetraceAudioMeter(
      aiPeak: aiPeak,
      userPeak: userPeak,
      tint: .white,
      intensity: .wide,
      style: meterStyle
    )
    .accessibilityHidden(true)
    .padding(.bottom, 7)
  }

  private var exitCapsule: some View {
    HStack(spacing: 6) {
      Image(systemName: "rectangle.portrait.and.arrow.forward")
        .font(.system(size: 13, weight: .semibold))
      Text("Exit")
        .font(.inter(.medium, size: 13))
    }
    .foregroundStyle(Color.white.opacity(0.96))
    .padding(.horizontal, 13)
    .padding(.vertical, 7)
    .background(
      Capsule()
        .fill(Color(red: 0.62, green: 0.16, blue: 0.18).opacity(0.55))
    )
    .rayBanHUDPanel(shape: .capsule)
    .hoverSelectable(exitControl, shape: .capsule, onConfirm: onExit)
  }
}
