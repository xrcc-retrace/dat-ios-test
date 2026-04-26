import SwiftUI

struct OnboardingWelcomeView: View {
  let onNext: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      Spacer()

      VStack(spacing: Spacing.xl) {
        Image("RetraceLogo")
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 220)
      }

      Spacer()

      VStack(spacing: Spacing.lg) {
        Text("Record an expert once.\nCoach every learner forever.")
          .font(.retraceTitle2)
          .foregroundColor(.textPrimary)
          .multilineTextAlignment(.center)
          .lineSpacing(4)

        Text("Retrace captures hands-on know-how from a first-person view, then coaches every learner hands-free through your glasses.")
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, Spacing.md)
      }
      .padding(.horizontal, Spacing.screenPadding)

      Spacer()
      Spacer()

      CustomButton(
        title: "Get Started",
        style: .primary,
        isDisabled: false,
        action: onNext
      )
      .padding(.horizontal, Spacing.screenPadding)
      .padding(.bottom, Spacing.xl)
    }
  }
}
