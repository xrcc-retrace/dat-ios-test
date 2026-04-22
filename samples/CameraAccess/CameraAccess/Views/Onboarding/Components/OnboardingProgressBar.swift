import SwiftUI

struct OnboardingProgressBar: View {
  let currentStep: Int
  let totalSteps: Int

  var body: some View {
    HStack(spacing: Spacing.xs) {
      ForEach(0..<totalSteps, id: \.self) { index in
        RoundedRectangle(cornerRadius: Radius.full)
          .fill(index < currentStep ? Color.textPrimary : Color.surfaceRaised)
          .frame(height: 3)
          .animation(.easeInOut(duration: 0.3), value: currentStep)
      }
    }
  }
}
