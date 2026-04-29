import SwiftUI

/// Replaces every other page when `viewModel.isCompleted` flips true.
/// Renders the completion summary + a single "Return to workflows" action
/// card. Tapping the pill (or the summary card) exits the session — the
/// parent decides where to route from there.
struct CoachingCompletionPage: RayBanHUDView {
  let onExit: () -> Void

  var body: some View {
    VStack(spacing: RayBanHUDLayoutTokens.stackSpacing) {
      Spacer(minLength: 0)

      RayBanHUDCompletionSummaryCard()

      RayBanHUDCompletionActionCard(
        icon: "sparkles.rectangle.stack.fill",
        label: "Return to workflows",
        id: .completionSavedWorkflows,
        onConfirm: onExit
      )

      Spacer(minLength: 0)
    }
    .padding(RayBanHUDLayoutTokens.contentPadding)
    .hudInputHandler { coord in
      CoachingCompletionPageHandler(coordinator: coord)
    }
  }
}
