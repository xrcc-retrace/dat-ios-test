import SwiftUI

struct StepProgressBar: View {
  let currentStep: Int
  let totalSteps: Int

  private var progress: CGFloat {
    guard totalSteps > 0 else { return 0 }
    return CGFloat(currentStep) / CGFloat(totalSteps)
  }

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: Radius.full)
          .fill(Color.surfaceRaised)
          .frame(height: 4)

        RoundedRectangle(cornerRadius: Radius.full)
          .fill(Color.textPrimary)
          .frame(width: geo.size.width * progress, height: 4)
          .animation(.easeInOut(duration: 0.3), value: currentStep)
      }
    }
    .frame(height: 4)
  }
}
