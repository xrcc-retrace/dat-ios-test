import SwiftUI

struct OnboardingControlsView: View {
  let onFinish: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Control hands-free.")
              .font(.retraceTitle1)
              .foregroundColor(.textPrimary)

            Text("On Ray-Ban Meta Display, Retrace responds to your voice and your fingers — no phone in hand.")
              .font(.retraceCallout)
              .foregroundColor(.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.top, Spacing.lg)
          .padding(.horizontal, Spacing.screenPadding)
          .padding(.bottom, Spacing.section)

          VStack(spacing: Spacing.section) {
            ControlsSection(header: "VOICE") {
              ControlRow(
                icon: "waveform",
                title: "Talk naturally",
                detail: "Ask questions, confirm steps, or describe what you see. We'll show example phrases when coaching starts."
              )
            }

            ControlsSection(header: "GESTURES") {
              VStack(spacing: 0) {
                ControlRow(
                  icon: "hand.pinch.fill",
                  title: "Pinch",
                  detail: "Confirm a step or select an item."
                )
                Divider().background(Color.borderSubtle.opacity(0.4))
                ControlRow(
                  icon: "hand.draw.fill",
                  title: "Drag",
                  detail: "Scroll through steps, clips, or lists."
                )
                Divider().background(Color.borderSubtle.opacity(0.4))
                ControlRow(
                  icon: "hand.tap.fill",
                  title: "Double pinch",
                  detail: "Go back."
                )
              }
            }
          }
          .padding(.horizontal, Spacing.screenPadding)
          .padding(.bottom, Spacing.xl)
        }
      }

      CustomButton(
        title: "Start using Retrace",
        style: .primary,
        isDisabled: false,
        action: onFinish
      )
      .padding(.horizontal, Spacing.screenPadding)
      .padding(.bottom, Spacing.xl)
    }
  }
}
