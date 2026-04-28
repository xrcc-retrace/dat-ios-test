import SwiftUI

// Static, non-interactive 3-stage explainer for the Troubleshoot landing.
// Maps to the system prompt's PHASE 1 (identify) → PHASE 2 (diagnose) →
// PHASE 3 (find a fix from library / manuals / web search).
struct TroubleshootFlowSummary: View {
  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      FlowStageCell(
        icon: "camera.viewfinder",
        label: "Identify",
        caption: "Camera spots the device"
      )
      ChevronDivider()
      FlowStageCell(
        icon: "magnifyingglass",
        label: "Diagnose",
        caption: "Ask and rule out"
      )
      ChevronDivider()
      FlowStageCell(
        icon: "globe",
        label: "Find a fix",
        caption: "Library, manuals, or web"
      )
    }
    .frame(maxWidth: .infinity)
  }
}

private struct FlowStageCell: View {
  let icon: String
  let label: String
  let caption: String

  var body: some View {
    VStack(alignment: .center, spacing: Spacing.sm) {
      ZStack {
        Circle()
          .fill(Color.appPrimary.opacity(0.18))
          .frame(width: 40, height: 40)
        Image(systemName: icon)
          .font(.system(size: 18, weight: .semibold))
          .foregroundColor(.appPrimary)
      }

      Text(label)
        .font(.retraceCaption1)
        .foregroundColor(.textPrimary)

      Text(caption)
        .font(.retraceCaption2)
        .foregroundColor(.textSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .top)
  }
}

private struct ChevronDivider: View {
  var body: some View {
    Image(systemName: "chevron.right")
      .font(.retraceCaption1)
      .foregroundColor(.textTertiary)
      .frame(width: 16)
      // Vertically align with the center of the 40pt icon circle in
      // FlowStageCell. The circle starts at y=0 of the cell, so its center
      // is at y=20.
      .padding(.top, 12)
  }
}
