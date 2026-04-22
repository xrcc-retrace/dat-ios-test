import SwiftUI

struct OnboardingCoachingStyleView: View {
  let onNext: () -> Void

  @AppStorage("autoAdvanceEnabled") private var autoAdvanceEnabled = true

  var body: some View {
    VStack(spacing: 0) {
      ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text("How should Gemini coach?")
              .font(.retraceTitle1)
              .foregroundColor(.textPrimary)
              .fixedSize(horizontal: false, vertical: true)

            Text("You can change this later in Profile.")
              .font(.retraceCallout)
              .foregroundColor(.textSecondary)
          }
          .padding(.top, Spacing.lg)
          .padding(.horizontal, Spacing.screenPadding)

          VStack(spacing: Spacing.xl) {
            CoachingStyleTile(
              icon: "waveform",
              name: "Active",
              description: "Gemini speaks up on its own — narrates steps, catches errors as they happen, and advances when you're done.",
              isSelected: autoAdvanceEnabled
            ) {
              autoAdvanceEnabled = true
            }

            CoachingStyleTile(
              icon: "hand.raised.fill",
              name: "Passive",
              description: "Gemini stays quiet until you ask. Best for learners who want to work at their own pace.",
              isSelected: !autoAdvanceEnabled
            ) {
              autoAdvanceEnabled = false
            }
          }
          .padding(.horizontal, Spacing.screenPadding)
          .padding(.top, Spacing.section)
          .padding(.bottom, Spacing.xl)
        }
      }

      CustomButton(
        title: "Next",
        style: .primary,
        isDisabled: false,
        action: onNext
      )
      .padding(.horizontal, Spacing.screenPadding)
      .padding(.bottom, Spacing.xl)
    }
  }
}
