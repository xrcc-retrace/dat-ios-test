import SwiftUI

/// On-demand registration sheet presented when the user taps a glasses-backed
/// CTA while unregistered. Wraps `HomeScreenView` (the existing connect-glasses
/// onboarding) and auto-dismisses once `registrationState` flips to
/// `.registered`, firing `onRegistered` so the caller can proceed with the
/// originally-requested action.
struct RegistrationPromptSheet: View {
  @ObservedObject var viewModel: WearablesViewModel
  let onRegistered: () -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      HomeScreenView(viewModel: viewModel)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") { dismiss() }
              .foregroundColor(.textSecondary)
          }
        }
        .retraceNavBar()
    }
    .onChange(of: viewModel.registrationState) { _, newState in
      if newState == .registered {
        dismiss()
        onRegistered()
      }
    }
  }
}
