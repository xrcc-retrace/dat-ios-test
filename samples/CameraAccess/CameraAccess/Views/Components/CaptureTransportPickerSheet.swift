import SwiftUI

struct CaptureTransportPickerSheet: View {
  let title: String
  let subtitle: String?
  let glassesActionLabel: String
  let iPhoneActionLabel: String
  let onSelect: (CaptureTransport) -> Void

  @Environment(\.dismiss) private var dismiss

  init(
    title: String,
    subtitle: String? = nil,
    glassesActionLabel: String,
    iPhoneActionLabel: String,
    onSelect: @escaping (CaptureTransport) -> Void
  ) {
    self.title = title
    self.subtitle = subtitle
    self.glassesActionLabel = glassesActionLabel
    self.iPhoneActionLabel = iPhoneActionLabel
    self.onSelect = onSelect
  }

  var body: some View {
    VStack(spacing: Spacing.xl) {
      VStack(spacing: Spacing.xs) {
        Text(title)
          .font(.retraceTitle3)
          .foregroundColor(.textPrimary)
          .multilineTextAlignment(.center)
        if let subtitle {
          Text(subtitle)
            .font(.retraceCallout)
            .foregroundColor(.textSecondary)
            .multilineTextAlignment(.center)
        }
      }
      .padding(.top, Spacing.xl)
      .padding(.horizontal, Spacing.screenPadding)

      VStack(spacing: Spacing.md) {
        CustomButton(
          title: glassesActionLabel,
          icon: "eyeglasses",
          style: .primary,
          isDisabled: false
        ) {
          select(.glasses)
        }

        CustomButton(
          title: iPhoneActionLabel,
          icon: "iphone",
          style: .secondary,
          isDisabled: false
        ) {
          select(.iPhone)
        }
      }
      .padding(.horizontal, Spacing.screenPadding)

      Spacer(minLength: 0)
    }
    .padding(.bottom, Spacing.xxl)
    .frame(maxWidth: .infinity, alignment: .top)
    .background(Color.backgroundPrimary)
    .presentationDetents([.height(subtitle == nil ? 260 : 300)])
    .presentationDragIndicator(.visible)
    .presentationBackground(Color.backgroundPrimary)
  }

  private func select(_ transport: CaptureTransport) {
    onSelect(transport)
    dismiss()
  }
}
