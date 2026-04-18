import SwiftUI

struct ProcedureCardView: View {
  let title: String
  let description: String
  let stepCount: Int
  let duration: Double
  let createdAt: String
  let status: String?

  var body: some View {
    HStack(spacing: Spacing.xl) {
      statusBadge
        .frame(width: 40, height: 40)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text(title)
          .font(.retraceHeadline)
          .foregroundColor(.textPrimary)
          .lineLimit(1)

        Text(description)
          .font(.retraceSubheadline)
          .foregroundColor(.textSecondary)
          .lineLimit(2)

        HStack(spacing: Spacing.md) {
          MetadataPill(icon: "clock", text: formattedDuration)
          MetadataPill(icon: "list.number", text: "\(stepCount) steps")
        }
      }

      Spacer()

      Image(systemName: "chevron.right")
        .font(.retraceSubheadline)
        .foregroundColor(.textTertiary)
    }
    .padding(Spacing.xxl)
    .background(Color.surfaceBase)
    .cornerRadius(Radius.lg)
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg)
        .stroke(borderColor, lineWidth: 1)
    )
  }

  @ViewBuilder
  private var statusBadge: some View {
    if status == "processing" {
      Circle()
        .fill(Color.iconSurface)
        .overlay(
          ProgressView()
            .scaleEffect(0.7)
            .tint(.textPrimary)
        )
    } else {
      Circle()
        .fill(Color.surfaceRaised)
        .overlay(
          Text("\(stepCount)")
            .font(Font.retraceHeadline)
            .fontWeight(.bold)
            .foregroundColor(.backgroundPrimary)
        )
    }
  }

  private var borderColor: Color {
    status == "processing" ? Color.semanticInfo.opacity(0.3) : Color.borderSubtle
  }

  private var formattedDuration: String {
    let mins = Int(duration) / 60
    let secs = Int(duration) % 60
    return String(format: "%d:%02d", mins, secs)
  }
}
