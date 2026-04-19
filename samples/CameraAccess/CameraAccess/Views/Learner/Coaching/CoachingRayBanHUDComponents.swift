import AVKit
import SwiftUI

enum RayBanHUDStepCardMode {
  case content(stepIndex: Int, stepCount: Int, step: ProcedureStepResponse?)
  case loading(stepIndex: Int?, stepCount: Int)
}

struct RayBanHUDExitPill: View {
  let isSelected: () -> Bool
  let onHoldStart: () -> Void
  let onHoldEnd: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "rectangle.portrait.and.arrow.forward")
        .font(.system(size: 24, weight: .medium))
        .frame(width: RayBanHUDLayoutTokens.iconFrame, height: RayBanHUDLayoutTokens.iconFrame)

      Text("Exit workflow")
        .font(.inter(.medium, size: 16))
        .lineLimit(1)
    }
    .foregroundStyle(Color.white.opacity(0.98))
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, 12)
    .rayBanHUDPanel(shape: .capsule)
    .hoverSelectable(.exitWorkflow, shape: .capsule, behavior: .selectOnly) {}
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

struct RayBanHUDStepCard: View {
  let mode: RayBanHUDStepCardMode
  let horizontalOffset: CGFloat
  let onConfirm: () -> Void
  let onDragChanged: (DragGesture.Value) -> Void
  let onDragEnded: (DragGesture.Value) -> Void
  let isSwipeEnabled: Bool

  var body: some View {
    cardSurface
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(RayBanHUDLayoutTokens.contentPadding)
      .frame(minHeight: RayBanHUDLayoutTokens.stepCardMinHeight, alignment: .center)
      .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
      .modifier(StepCardHoverModifier(isInteractive: isContentMode, onConfirm: onConfirm))
      .contentShape(RoundedRectangle(cornerRadius: RayBanHUDLayoutTokens.cardRadius, style: .continuous))
      .offset(x: horizontalOffset)
      .simultaneousGesture(
        DragGesture(minimumDistance: RayBanHUDLayoutTokens.stepSwipeMinimumDistance)
          .onChanged { value in
            guard isSwipeEnabled, isContentMode else { return }
            onDragChanged(value)
          }
          .onEnded { value in
            guard isSwipeEnabled, isContentMode else { return }
            onDragEnded(value)
          }
      )
  }

  @ViewBuilder
  private var cardSurface: some View {
    switch mode {
    case .content(let stepIndex, let stepCount, let step):
      VStack(alignment: .leading, spacing: 12) {
        Text("STEP \(stepIndex) OF \(stepCount)")
          .font(.inter(.medium, size: 12))
          .tracking(1.2)
          .foregroundStyle(Color.white.opacity(0.9))

        if let step {
          Text(step.title)
            .font(.inter(.bold, size: 24))
            .foregroundStyle(Color.white.opacity(0.98))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)

          Text(step.description)
            .font(.inter(.medium, size: 16))
            .foregroundStyle(Color.white.opacity(0.96))
            .lineSpacing(3)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

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

  private var isContentMode: Bool {
    if case .content = mode {
      return true
    }
    return false
  }
}

struct RayBanHUDDetailPanel: View {
  let clipURL: URL?
  let onConfirm: () -> Void

  var body: some View {
    Group {
      if let clipURL {
        RayBanHUDReferenceClipPlayer(
          url: clipURL,
          cornerRadius: RayBanHUDLayoutTokens.cardRadius
        )
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
    .hoverSelectable(.detailCollapse, shape: .rounded(RayBanHUDLayoutTokens.cardRadius), onConfirm: onConfirm)
  }

  private var noClipPlaceholder: some View {
    ZStack {
      Color.black.opacity(0.28)

      VStack(spacing: 10) {
        Image(systemName: "film.stack")
          .font(.system(size: 24, weight: .medium))
          .foregroundStyle(Color.white.opacity(0.78))

        Text("No reference clip for this step")
          .font(.inter(.medium, size: 16))
          .foregroundStyle(Color.white.opacity(0.82))
      }
      .multilineTextAlignment(.center)
      .padding(RayBanHUDLayoutTokens.contentPadding)
    }
  }
}

struct RayBanHUDExitOverlay: View {
  let progress: CGFloat
  let onCancel: () -> Void

  var body: some View {
    VStack {
      Spacer(minLength: 0)

      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text("Exit workflow")
            .font(.inter(.bold, size: 24))
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
              .fill(Color(red: 1.0, green: 0.76, blue: 0.11))
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

  private var clampedProgress: CGFloat {
    max(0, min(progress, 1))
  }

  private var remainingSeconds: Int {
    let remaining = max(
      0,
      RayBanHUDLayoutTokens.exitHoldDuration - (RayBanHUDLayoutTokens.exitHoldDuration * Double(clampedProgress))
    )
    return Int(ceil(remaining))
  }
}

struct RayBanHUDCompletionSummaryCard: View {
  let onConfirm: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 72, weight: .regular))
        .foregroundStyle(completionGradient)
        .frame(height: 76)

      Text("You’re all done. Great job!")
        .font(.inter(.bold, size: 20))
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
        .font(.system(size: 22, weight: .medium))
        .frame(width: RayBanHUDLayoutTokens.iconFrame, height: RayBanHUDLayoutTokens.iconFrame)

      Text(label)
        .font(.inter(.medium, size: 18))

      Spacer(minLength: 0)
    }
    .foregroundStyle(Color.white.opacity(0.98))
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity)
    .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.completionActionRadius))
    .hoverSelectable(
      id,
      shape: .rounded(RayBanHUDLayoutTokens.completionActionRadius),
      onConfirm: onConfirm
    )
  }
}

private struct StepCardHoverModifier: ViewModifier {
  let isInteractive: Bool
  let onConfirm: () -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    if isInteractive {
      content.hoverSelectable(
        .stepCard,
        shape: .rounded(RayBanHUDLayoutTokens.cardRadius),
        onConfirm: onConfirm
      )
    } else {
      content
    }
  }
}

private struct RayBanHUDReferenceClipPlayer: View {
  let url: URL
  let cornerRadius: CGFloat

  @State private var player: AVPlayer?

  var body: some View {
    ZStack {
      if let player {
        VideoPlayer(player: player)
      } else {
        ZStack {
          VideoThumbnailView(url: url)

          Button {
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
          } label: {
            Image(systemName: "play.circle.fill")
              .font(.system(size: 42, weight: .regular))
              .foregroundStyle(Color.white.opacity(0.92))
              .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
          }
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }
}
