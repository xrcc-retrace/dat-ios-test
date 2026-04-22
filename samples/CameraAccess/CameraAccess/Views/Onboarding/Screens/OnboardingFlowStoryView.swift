import SwiftUI

struct OnboardingFlowStoryView: View {
  let onNext: () -> Void

  @State private var revealStep: Int = 0
  @State private var hintPulse: Bool = false

  private var headline: String {
    switch revealStep {
    case 0: return "An expert records once."
    case 1: return "Every learner gets coached."
    default: return "Troubleshoot pulls it together."
    }
  }

  private var body_: String {
    switch revealStep {
    case 0:
      return "Someone who knows the job records a procedure. Retrace turns it into a step-by-step SOP with video clips."
    case 1:
      return "Gemini Live watches and listens as the learner works — narrating steps, catching mistakes, and advancing when each one is done."
    default:
      return "When something breaks, Troubleshoot identifies the product, finds the right SOP, and hands off to a coached session."
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: Spacing.section)

      VStack(alignment: .leading, spacing: Spacing.lg) {
        Text(headline)
          .font(.retraceTitle1)
          .foregroundColor(.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .id("headline-\(revealStep)")
          .transition(.opacity)

        Text(body_)
          .font(.retraceBody)
          .foregroundColor(.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(minHeight: 88, alignment: .top)
          .id("body-\(revealStep)")
          .transition(.opacity)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Spacing.screenPadding)
      .animation(.easeInOut(duration: 0.28), value: revealStep)

      Spacer()

      diagram
        .padding(.horizontal, Spacing.screenPadding)

      Spacer()

      VStack(spacing: Spacing.md) {
        if revealStep < 2 {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "hand.tap.fill")
              .font(.system(size: 12, weight: .semibold))
            Text("Tap to continue")
              .font(.retraceCaption1)
          }
          .foregroundColor(.textTertiary)
          .opacity(hintPulse ? 1.0 : 0.35)
          .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: hintPulse)
          .transition(.opacity)
        }

        CustomButton(
          title: "Next",
          style: .primary,
          isDisabled: revealStep < 2,
          action: onNext
        )
      }
      .padding(.horizontal, Spacing.screenPadding)
      .padding(.bottom, Spacing.xl)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      guard revealStep < 2 else { return }
      withAnimation(.easeOut(duration: 0.4)) {
        revealStep += 1
      }
    }
    .onAppear { hintPulse = true }
  }

  private var diagram: some View {
    HStack(spacing: 0) {
      OnboardingFlowNode(icon: "video.fill", label: "Expert", isActive: true)

      if revealStep >= 1 {
        connector
        OnboardingFlowNode(icon: "person.wave.2.fill", label: "Learner", isActive: true)
          .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity
          ))
      } else {
        Spacer(minLength: 0)
      }

      if revealStep >= 2 {
        connector
        OnboardingFlowNode(icon: "stethoscope", label: "Troubleshoot", isActive: true)
          .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity
          ))
      } else if revealStep == 1 {
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 112)
  }

  private var connector: some View {
    Image(systemName: "arrow.right")
      .font(.system(size: 14, weight: .semibold))
      .foregroundColor(.textTertiary)
      .padding(.horizontal, Spacing.xs)
      .frame(maxWidth: .infinity)
      .transition(.opacity)
  }
}
