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
  @Environment(\.hudAdditiveSurfaceVariant) private var additiveSurfaceVariant

  func body(content: Content) -> some View {
    if isFlatSurface {
      content
        .background {
          HUDSurfaceBackground(shape: shape)
        }
    } else {
      content
        .background {
          HUDSurfaceBackground(shape: shape)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 10)
    }
  }

  // Expert + Troubleshoot pass `.lowTint` — both sit directly over the
  // live camera preview, where each shadow forces an offscreen blur pass
  // per panel per frame. Drop the shadow there regardless of the
  // additive toggle. Coaching keeps `.standard` and its shadow.
  private var isFlatSurface: Bool {
    additiveSurfaceVariant == .lowTint
  }
}

extension View {
  func rayBanHUDPanel(shape: HUDSurfaceShape) -> some View {
    modifier(RayBanHUDPanelModifier(shape: shape))
  }

  /// Canonical recede applied to lens content while a confirmation
  /// overlay is on top. Shrinks, dims, blurs, and disables hit-testing
  /// in one pass — the overlay's own `.transition(.scale(0.88).combined(.opacity))`
  /// + the parent's animation block produce the matched arrive motion.
  /// See DESIGN.md → Animation System → Recede + arrive pattern.
  ///
  /// Single source of truth — every confirmation overlay (Coaching exit,
  /// Troubleshoot identify-confirm + end-diagnostic, Expert stop-recording
  /// countdown) now reaches for this. Tweaking the recede intensity is
  /// one place, not three.
  func rayBanHUDRecede(active: Bool) -> some View {
    self
      .scaleEffect(active ? RayBanHUDLayoutTokens.recedeScale : 1.0)
      .opacity(active ? RayBanHUDLayoutTokens.recedeOpacity : 1.0)
      .blur(radius: active ? RayBanHUDLayoutTokens.recedeBlurRadius : 0)
      .allowsHitTesting(!active)
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

/// Unified hover ring used by every `.hoverSelectable` element on the lens.
///
/// Yellow accent (`Color(1.0, 0.76, 0.11)`) was always the canonical
/// highlight color in `DESIGN.md`'s palette table; the previous white
/// implementation was doc/code drift. Yellow has high luminance so it
/// composites cleanly under the lens's `.plusLighter` additive blend on
/// both bright (white wall) and dark (low-light) camera scenes — pure
/// white loses chroma separation against bright walls; saturated hues
/// (red / blue / rainbow stops) halate unpredictably against colored
/// scene content.
///
/// 2pt stroke + warm glow makes the ring obvious enough that the user
/// can tell at a glance which element is targeted, without crossing
/// into "selected fill" territory (that role belongs to toggle pills'
/// permanent `white @ 0.95` fill, see DESIGN.md → Pills).
struct HUDHoverHighlight: View {
  let shape: HUDSurfaceShape
  let isVisible: Bool

  /// Canonical highlight accent. Mirrors `DESIGN.md` → Color Palette →
  /// "Highlight accent" row. Kept as a static so the doc comment and
  /// the three gradient stops below all reference one source.
  private static let accent = Color(red: 1.0, green: 0.76, blue: 0.11)
  /// Lighter, slightly desaturated yellow used at the bottom-trailing
  /// stop so the gradient pulls toward the panel's white sheen instead
  /// of cutting off abruptly.
  private static let accentSoft = Color(red: 1.0, green: 0.84, blue: 0.38)

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
        .strokeBorder(strokeGradient, lineWidth: 2)
        .padding(-1)
        .shadow(color: Self.accent.opacity(0.55), radius: 8, x: 0, y: 0)
    case .rounded(let radius):
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(strokeGradient, lineWidth: 2)
        .padding(-1)
        .shadow(color: Self.accent.opacity(0.55), radius: 8, x: 0, y: 0)
    }
  }

  private var fillGradient: LinearGradient {
    // Barely-perceptible warm tint inside the ring. Its job is to
    // suppress panel flicker as the highlight fades in, not to fill
    // the button — that would compete with the toggle-pill "selected"
    // fill convention.
    LinearGradient(
      colors: [
        Self.accent.opacity(0.10),
        Self.accent.opacity(0.04),
        .clear,
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var strokeGradient: LinearGradient {
    // Top-leading → bottom-trailing matches the panel's sheen
    // direction so the ring feels integrated with the surface.
    LinearGradient(
      colors: [
        Self.accent.opacity(1.0),
        Self.accent.opacity(0.70),
        Self.accentSoft.opacity(0.45),
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

  /// Mirrors the same AppStorage key `HandTrackingStatusIndicator`
  /// reads. When the user disables hand tracking in Server Settings →
  /// Debug, the indicator returns EmptyView and we replace its slot
  /// with elastic flex space — the meter then sits centered between
  /// Mute (left elastic) and Exit (right elastic).
  @AppStorage("disableHandTracking") private var disableHandTracking: Bool = false

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
    // Layout invariants:
    //   1. Mute capsule: `.frame(maxWidth: .infinity, alignment: .leading)`
    //      makes it the elastic element — it expands to fill all the
    //      leftover horizontal space with the visible pill pinned at
    //      the leading edge. No explicit `Spacer()` view; the pill's
    //      own frame does the work.
    //   2. Audio meter has a FIXED width (not `maxWidth`) so it can't
    //      grow into the Exit pill or shrink under pressure.
    //   3. Hand indicator has its own fixed 22pt frame.
    //   4. Exit pill: `.layoutPriority(1)` so it always renders at its
    //      full ideal width — text never clips when "Unmute" makes
    //      the left side longer.
    //   5. Tight HStack spacing (4) keeps meter / hand / exit reading
    //      as a single right-anchored cluster with minimal gap
    //      between them.
    // Two layouts — only the audio-meter placement differs between
    // them. Everything else (mute pill, exit pill, sizes, spacing)
    // is identical across branches.
    //
    // - Hand tracking ON: meter is sized to 64pt and tucked next to
    //   the hand indicator + exit pill on the right, with mute
    //   pinned left via an elastic frame.
    // - Hand tracking OFF: meter is sized to 64pt and centered
    //   between mute and exit via symmetric `Spacer()`s.
    HStack(alignment: .bottom, spacing: 6) {
      if disableHandTracking {
        muteCapsule

        Spacer(minLength: 0)

        wideAudioMeter
          .frame(width: 64)

        Spacer(minLength: 0)

        exitCapsule
          .layoutPriority(1)
      } else {
        muteCapsule
          .frame(maxWidth: .infinity, alignment: .leading)

        wideAudioMeter
          .frame(width: 64)
          // Extra trailing pad on the meter (in addition to the
          // HStack's 6pt spacing) so the bar's right edge sits with
          // visible breathing room before the hand icon.
          .padding(.trailing, 14)

        HandTrackingStatusIndicator()

        exitCapsule
          .layoutPriority(1)
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
