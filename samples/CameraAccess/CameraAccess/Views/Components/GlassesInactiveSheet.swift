import SwiftUI

/// Lightweight sheet presented when the user taps a glasses-backed action
/// (Record with Glasses / Coach with Glasses) while registered but with no
/// actively-reachable device. Explains why the action is blocked and offers
/// an iPhone fallback so the user isn't stuck.
struct GlassesInactiveSheet: View {
  let iPhoneAlternativeTitle: String
  let onUseIPhoneInstead: () -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: Spacing.section) {
      Image(systemName: "eyeglasses")
        .font(.system(size: 48))
        .foregroundColor(.textTertiary)

      VStack(spacing: Spacing.md) {
        Text("Glasses aren't connected")
          .font(.retraceTitle2)
          .fontWeight(.semibold)
          .foregroundColor(.textPrimary)

        Text("Make sure your glasses are on, out of the case, and within range.")
          .font(.retraceBody)
          .foregroundColor(.textSecondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: Spacing.lg) {
        CustomButton(title: "Got it", style: .primary, isDisabled: false) {
          dismiss()
        }

        CustomButton(
          title: iPhoneAlternativeTitle,
          icon: "iphone",
          style: .secondary,
          isDisabled: false
        ) {
          dismiss()
          onUseIPhoneInstead()
        }
      }
    }
    .padding(Spacing.screenPadding)
    .frame(maxWidth: .infinity)
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
  }
}
