import SwiftUI

enum HUDSurfaceShape: Equatable {
  case capsule
  case rounded(CGFloat)
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

extension EnvironmentValues {
  var hudAdditiveBlend: Bool {
    get { self[HUDAdditiveBlendKey.self] }
    set { self[HUDAdditiveBlendKey.self] = newValue }
  }
}

struct RayBanHUDPanelModifier: ViewModifier {
  let shape: HUDSurfaceShape

  func body(content: Content) -> some View {
    content
      .background {
        HUDSurfaceBackground(shape: shape)
      }
      .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 10)
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
      // Near-black "dark container" — under `.plusLighter` this composites
      // to ~transparent (camera passes through unchanged) and gives white
      // text a clean low-luminance neighborhood instead of the halated
      // mid-gray that bled into adjacent pixels. The faint top-leading
      // lift keeps the panel from looking flat-black at the apex.
      return LinearGradient(
        colors: [
          Color(red: 0.04, green: 0.05, blue: 0.06).opacity(0.92),
          Color(red: 0.02, green: 0.02, blue: 0.03).opacity(0.92),
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
      // Drop the white-ish lift under additive — those bright stops are
      // halation sources. Keep only the dark stop so the gradient stays
      // luminance-neutral on the camera.
      return LinearGradient(
        colors: [
          Color.clear,
          Color.clear,
          Color.black.opacity(0.18),
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
