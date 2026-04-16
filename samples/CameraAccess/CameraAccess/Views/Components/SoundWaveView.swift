import SwiftUI

struct SoundWaveView: View {
  let isActive: Bool
  let color: Color

  @State private var animating = false

  var body: some View {
    HStack(spacing: 2) {
      ForEach(0..<3, id: \.self) { index in
        RoundedRectangle(cornerRadius: 1)
          .fill(color)
          .frame(width: 3, height: barHeight(for: index))
          .animation(
            isActive
              ? .easeInOut(duration: 0.4 + Double(index) * 0.15)
                .repeatForever(autoreverses: true)
              : .easeOut(duration: 0.2),
            value: animating
          )
      }
    }
    .frame(height: 16)
    .onChange(of: isActive) { _, active in
      animating = active
    }
    .onAppear {
      if isActive { animating = true }
    }
  }

  private func barHeight(for index: Int) -> CGFloat {
    if !animating {
      return 4
    }
    switch index {
    case 0: return 10
    case 1: return 16
    case 2: return 8
    default: return 4
    }
  }
}
