import SwiftUI

/// Replaces every other page when `viewModel.isCompleted` flips true.
/// Renders the completion summary + the two action cards (Saved Workflows,
/// Troubleshoot). Tapping any pill exits the session — the parent decides
/// where to route from there.
struct CoachingCompletionPage: RayBanHUDView {
  let onExit: () -> Void

  var body: some View {
    VStack(spacing: RayBanHUDLayoutTokens.stackSpacing) {
      Spacer(minLength: 0)

      RayBanHUDCompletionSummaryCard(onConfirm: onExit)

      RayBanHUDCompletionActionCard(
        icon: "sparkles.rectangle.stack.fill",
        label: "Saved Workflows",
        id: .completionSavedWorkflows,
        onConfirm: onExit
      )

      RayBanHUDCompletionActionCard(
        icon: "stethoscope",
        label: "Troubleshoot",
        id: .completionTroubleshoot,
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
