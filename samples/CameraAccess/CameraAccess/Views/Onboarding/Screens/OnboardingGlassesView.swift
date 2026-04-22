import MWDATCore
import SwiftUI

struct OnboardingGlassesView: View {
  @ObservedObject var wearablesVM: WearablesViewModel
  let onNext: () -> Void

  private var isRegistering: Bool {
    wearablesVM.registrationState == .registering
  }

  private var isRegistered: Bool {
    wearablesVM.registrationState == .registered
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView(showsIndicators: false) {
        VStack(spacing: 0) {
          heroArt
            .padding(.top, Spacing.section)

          VStack(spacing: Spacing.md) {
            Text("Connect your Ray-Ban Meta.")
              .font(.retraceTitle1)
              .foregroundColor(.textPrimary)
              .multilineTextAlignment(.center)

            Text("Glasses unlock first-person recording and open-ear coaching. Retrace runs fully without them too.")
              .font(.retraceCallout)
              .foregroundColor(.textSecondary)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.horizontal, Spacing.screenPadding)
          .padding(.top, Spacing.section)

          statusLine
            .padding(.top, Spacing.xl)

          VStack(spacing: Spacing.md) {
            benefitRow(icon: "mic.fill", text: "Speak commands hands-free.")
            benefitRow(icon: "hand.point.up.left.fill", text: "Pinch and drag gestures for control.")
            benefitRow(icon: "ear.fill", text: "Open-ear audio — hear the world around you.")
          }
          .padding(.horizontal, Spacing.screenPadding)
          .padding(.top, Spacing.section)
          .padding(.bottom, Spacing.xl)
        }
      }

      VStack(spacing: Spacing.md) {
        CustomButton(
          title: isRegistered ? "Connected" : (isRegistering ? "Connecting…" : "Connect my glasses"),
          icon: isRegistered ? "checkmark" : "eyeglasses",
          style: .primary,
          isDisabled: isRegistering || isRegistered
        ) {
          wearablesVM.connectGlasses()
        }

        CustomButton(
          title: isRegistered ? "Continue" : "Skip for now",
          style: .ghost,
          isDisabled: false,
          action: onNext
        )

        Text("You can connect glasses later from Profile.")
          .font(.retraceCaption1)
          .foregroundColor(.textTertiary)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, Spacing.screenPadding)
      .padding(.bottom, Spacing.xl)
    }
    .onChange(of: wearablesVM.registrationState) { _, newState in
      if newState == .registered {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
          onNext()
        }
      }
    }
  }

  private var heroArt: some View {
    ZStack {
      Circle()
        .fill(Color.surfaceBase)
        .frame(width: 160, height: 160)

      Image(systemName: "eyeglasses")
        .font(.system(size: 72, weight: .regular))
        .foregroundColor(.textPrimary)
    }
  }

  private var statusLine: some View {
    HStack(spacing: Spacing.sm) {
      Circle()
        .fill(statusColor)
        .frame(width: 6, height: 6)
        .scaleEffect(isRegistering ? 1.3 : 1.0)
        .opacity(isRegistering ? 0.6 : 1.0)
        .animation(
          isRegistering
            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
            : .default,
          value: isRegistering
        )

      Text(statusText)
        .font(.retraceCaption1)
        .foregroundColor(.textSecondary)
    }
  }

  private var statusColor: Color {
    if isRegistered { return .semanticSuccess }
    if isRegistering { return .appPrimary }
    return .textTertiary
  }

  private var statusText: String {
    if isRegistered { return "Glasses connected" }
    if isRegistering { return "Waiting for Meta AI app…" }
    return "Not connected"
  }

  private func benefitRow(icon: String, text: String) -> some View {
    HStack(spacing: Spacing.lg) {
      Image(systemName: icon)
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(.textPrimary)
        .frame(width: 28)

      Text(text)
        .font(.retraceCallout)
        .foregroundColor(.textSecondary)

      Spacer(minLength: 0)
    }
  }
}
