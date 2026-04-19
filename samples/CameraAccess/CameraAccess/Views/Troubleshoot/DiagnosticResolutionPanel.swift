import SwiftUI

/// Rendered during `.resolving`/`.resolved`. Three sub-states per the
/// designer spec: matched procedure, freshly-generated SOP, or no-match.
struct DiagnosticResolutionPanel: View {
  let resolution: DiagnosticResolution
  let isHandoffInFlight: Bool
  let handoffError: String?
  let onStartProcedure: (String) -> Void
  let onRetry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text(overline)
        .font(.retraceOverline)
        .tracking(1)
        .foregroundColor(.textSecondary)

      Text(title)
        .font(.retraceTitle3)
        .foregroundColor(.textPrimary)

      if let subtitle {
        Text(subtitle)
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let err = handoffError {
        Text(err)
          .font(.retraceCaption1)
          .foregroundColor(.appPrimary)
      }

      VStack(spacing: Spacing.sm) {
        switch resolution {
        case .matchedProcedure(let c):
          CustomButton(
            title: isHandoffInFlight ? "Starting…" : "Start Procedure",
            icon: isHandoffInFlight ? nil : "play.fill",
            style: .primary,
            isDisabled: isHandoffInFlight
          ) {
            onStartProcedure(c.procedureId)
          }

        case .generatedSOP(let procedureId, _):
          CustomButton(
            title: isHandoffInFlight ? "Starting…" : "Start Procedure",
            icon: isHandoffInFlight ? nil : "play.fill",
            style: .primary,
            isDisabled: isHandoffInFlight
          ) {
            onStartProcedure(procedureId)
          }

        case .noMatch:
          CustomButton(
            title: "Try Again",
            icon: "arrow.clockwise",
            style: .primary,
            isDisabled: false
          ) {
            onRetry()
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.xl)
    .glassPanel(cornerRadius: Radius.xl)
    .padding(.horizontal, Spacing.xl)
  }

  private var overline: String {
    switch resolution {
    case .matchedProcedure: return "DIAGNOSIS COMPLETE"
    case .generatedSOP:     return "PROCEDURE GENERATED"
    case .noMatch:          return "NO MATCH FOUND"
    }
  }

  private var title: String {
    switch resolution {
    case .matchedProcedure(let c): return c.title
    case .generatedSOP(_, let t):  return t
    case .noMatch:                 return "Couldn't identify a fix"
    }
  }

  private var subtitle: String? {
    switch resolution {
    case .matchedProcedure(let c): return c.matchReason
    case .generatedSOP:            return "AI-generated from a manufacturer manual."
    case .noMatch:                 return "No matching procedure found for the symptoms described."
    }
  }
}
