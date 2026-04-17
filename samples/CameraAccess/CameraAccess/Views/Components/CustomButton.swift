import SwiftUI

struct CustomButton: View {
  let title: String
  let icon: String?
  let style: ButtonVariant
  let isDisabled: Bool
  let action: () -> Void

  init(
    title: String,
    icon: String? = nil,
    style: ButtonVariant,
    isDisabled: Bool,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.icon = icon
    self.style = style
    self.isDisabled = isDisabled
    self.action = action
  }

  enum ButtonVariant {
    case primary, secondary, ghost, destructive

    var backgroundColor: Color {
      switch self {
      case .primary: return .appPrimary
      case .secondary: return .surfaceRaised
      case .ghost: return .clear
      case .destructive: return .semanticError
      }
    }

    var foregroundColor: Color {
      switch self {
      case .primary: return .backgroundPrimary
      case .secondary: return .textPrimary
      case .ghost: return .appPrimary
      case .destructive: return .white
      }
    }

    var hasBorder: Bool {
      self == .secondary
    }
  }

  @State private var isPressed = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: Spacing.md) {
        if let icon {
          Image(systemName: icon)
            .font(.retraceBody)
            .fontWeight(.semibold)
        }
        Text(title)
          .font(.retraceBody)
          .fontWeight(.semibold)
      }
      .foregroundColor(style.foregroundColor)
      .frame(maxWidth: .infinity)
      .frame(height: 52)
      .background(style.backgroundColor)
      .cornerRadius(Radius.full)
      .overlay(
        Group {
          if style.hasBorder {
            RoundedRectangle(cornerRadius: Radius.full)
              .stroke(Color.borderSubtle, lineWidth: 1)
          }
        }
      )
    }
    .buttonStyle(ScaleButtonStyle())
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.5 : 1.0)
  }
}

struct ScaleButtonStyle: SwiftUI.ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
      .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
  }
}
