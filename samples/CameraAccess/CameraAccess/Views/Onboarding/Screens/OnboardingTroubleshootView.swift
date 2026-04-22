import SwiftUI

struct OnboardingTroubleshootView: View {
  let onNext: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Troubleshoot Mode")
              .font(.retraceTitle1)
              .foregroundColor(.textPrimary)

            Text("Broken product, no matching SOP? Describe it — Gemini diagnoses and coaches.")
              .font(.retraceCallout)
              .foregroundColor(.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.top, Spacing.lg)
          .padding(.horizontal, Spacing.screenPadding)

          VStack(alignment: .leading, spacing: Spacing.lg) {
            OnboardingPhaseRow(
              number: 1,
              icon: "stethoscope",
              title: "Diagnose",
              detail: "Describe what's broken. Gemini identifies the product and the likely failure mode."
            )

            connector

            OnboardingPhaseRow(
              number: 2,
              icon: "doc.text.magnifyingglass",
              title: "Analysis",
              detail: "Gemini searches your procedure library or fetches the manual if it's missing."
            )

            connector

            OnboardingPhaseRow(
              number: 3,
              icon: "arrow.right.circle.fill",
              title: "Handoff",
              detail: "The best procedure opens as a full coaching session — step-by-step, voice-guided."
            )
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

  private var connector: some View {
    Rectangle()
      .fill(Color.surfaceRaised)
      .frame(width: 2, height: 16)
      .padding(.leading, 13)
  }

  private var calloutView: some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      Image(systemName: "sparkles")
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(.textPrimary)
        .padding(.top, 2)

      Text("No procedure needed to start. Gemini can ingest a PDF manual on the spot.")
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
