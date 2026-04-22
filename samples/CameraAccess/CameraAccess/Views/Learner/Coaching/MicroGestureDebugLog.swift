import SwiftUI

/// Temporary debug overlay for the Ray-Ban HUD that visualizes every
/// emission from `PinchDragRecognizer`. Renders a compact scrollable
/// feed — by default only the newest entry is visible, earlier ones are
/// reachable by scrolling up inside the fixed-height container.
///
/// Styled with `rayBanHUDPanel` so it reads as native HUD chrome, not
/// an afterthought overlay. File is named `MicroGestureDebugLog` for
/// historical reasons (used to show `HandGestureEvent`s from the Meta XR
/// recognizer); a rename pass can happen after the demo.
struct MicroGestureDebugLog: View {
  let entries: [PinchDragLogEntry]

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .trailing, spacing: 6) {
          ForEach(entries) { entry in
            MicroGestureBadgeRow(entry: entry)
              .id(entry.id)
              .transition(
                .asymmetric(
                  insertion: .move(edge: .trailing).combined(with: .opacity),
                  removal: .opacity
                )
              )
          }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
      }
      .frame(width: 220, height: 56)
      .rayBanHUDPanel(shape: .rounded(18))
      .onChange(of: entries.last?.id) { _, newestId in
        guard let newestId else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
          proxy.scrollTo(newestId, anchor: .bottom)
        }
      }
      .onAppear {
        if let newestId = entries.last?.id {
          proxy.scrollTo(newestId, anchor: .bottom)
        }
      }
    }
    // Debug-only affordance — don't block underlying HUD interactions.
    .allowsHitTesting(false)
  }
}

private struct MicroGestureBadgeRow: View {
  let entry: PinchDragLogEntry

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: entry.event.symbolName)
        .font(.system(size: 13, weight: .semibold))
      Text(entry.event.displayName)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
    }
    .foregroundStyle(Color.white)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(
      Capsule().fill(Color.black.opacity(0.28))
    )
    .overlay(
      Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
    )
    .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

private extension PinchDragEvent {
  var displayName: String {
    switch self {
    case .select: return "Select"
    case .cancel: return "Cancel"
    case .left: return "Left"
    case .right: return "Right"
    case .up: return "Up"
    case .down: return "Down"
    case .back: return "Back"
    case .highlightLeft: return "Hi ◀"
    case .highlightRight: return "Hi ▶"
    case .highlightUp: return "Hi ▲"
    case .highlightDown: return "Hi ▼"
    }
  }

  var symbolName: String {
    switch self {
    case .select: return "hand.tap.fill"
    case .cancel: return "xmark.circle.fill"
    case .left: return "arrow.left"
    case .right: return "arrow.right"
    case .up: return "arrow.up"
    case .down: return "arrow.down"
    case .back: return "arrow.uturn.backward"
    case .highlightLeft: return "chevron.left"
    case .highlightRight: return "chevron.right"
    case .highlightUp: return "chevron.up"
    case .highlightDown: return "chevron.down"
    }
  }
}
