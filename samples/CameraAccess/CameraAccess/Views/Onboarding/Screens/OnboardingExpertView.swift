import SwiftUI

struct OnboardingExpertView: View {
  let onNext: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Expert Mode")
              .font(.retraceTitle1)
              .foregroundColor(.textPrimary)

            Text("Two ways to capture a procedure for your learners.")
              .font(.retraceCallout)
              .foregroundColor(.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.top, Spacing.lg)
          .padding(.horizontal, Spacing.screenPadding)

          VStack(spacing: Spacing.xl) {
            ModeCard(
              icon: "eyeglasses",
              title: "Record with Glasses",
              subtitle: "Egocentric, hands-free capture from your Ray-Ban Meta.",
              isEnabled: true,
              action: {}
            )
            .allowsHitTesting(false)

            ModeCard(
              icon: "doc.fill",
              title: "Upload a PDF Manual",
              subtitle: "Retrace ingests any SOP document into a coached procedure.",
              isEnabled: true,
              action: {}
            )
            .allowsHitTesting(false)
          }
          .padding(.horizontal, Spacing.screenPadding)
          .padding(.top, Spacing.section)

          calloutView
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.top, Spacing.xxl)
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

  private var calloutView: some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      Image(systemName: "sparkles")
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(.textPrimary)
        .padding(.top, 2)

      Text("Glasses give Gemini the same first-person view it will coach from.")
        .font(.retraceCaption1)
        .foregroundColor(.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)
    }
    .padding(Spacing.xl)
    .background(Color.surfaceBase)
    .cornerRadius(Radius.md)
  }
}
