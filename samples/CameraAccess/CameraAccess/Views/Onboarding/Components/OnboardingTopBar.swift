import SwiftUI

struct OnboardingTopBar: View {
  let currentStep: Int
  let totalSteps: Int
  let onBack: (() -> Void)?
  let onSkip: () -> Void

  var body: some View {
    HStack(spacing: Spacing.lg) {
      Group {
        if let onBack {
          Button(action: onBack) {
            Image(systemName: "chevron.left")
              .font(.system(size: 17, weight: .semibold))
              .foregroundColor(.textPrimary)
              .frame(width: 32, height: 32)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        } else {
          Color.clear.frame(width: 32, height: 32)
        }
      }

      OnboardingProgressBar(currentStep: currentStep, totalSteps: totalSteps)
        .frame(maxWidth: .infinity)

      Button(action: onSkip) {
        Text("Skip")
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
          .frame(height: 32)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, Spacing.screenPadding)
    .padding(.top, Spacing.md)
    .padding(.bottom, Spacing.lg)
  }
}
