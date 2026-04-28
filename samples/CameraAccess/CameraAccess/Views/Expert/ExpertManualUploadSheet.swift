import SwiftUI

/// Two-phase upload progress sheet:
///   Phase 1 — Uploading. Indeterminate spinner while the multipart POST
///             completes (the upload itself is fast; we don't expose
///             per-byte progress).
///   Phase 2 — Analyzing. Spinner + "Keep working in the background"
///             escape that drops the user back to the Workflows tab where
///             the new procedure already shows up with status: processing.
///
/// On `.ready` the sheet auto-dismisses and forwards the new procedure
/// id. On `.failed` it surfaces the error with a Try Again / Close pair.
struct ExpertManualUploadSheet: View {
  @ObservedObject var viewModel: ManualUploadViewModel
  let onComplete: (_ procedureId: String) -> Void
  let onDismiss: () -> Void
  let onSendToBackground: () -> Void
  let onRetry: () -> Void

  var body: some View {
    NavigationStack {
      RetraceScreen {
        VStack(spacing: Spacing.section) {
          Spacer()
          phaseContent
          Spacer()
          actionRow
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.bottom, Spacing.section)
      }
      .navigationTitle("Importing Manual")
      .navigationBarTitleDisplayMode(.inline)
      .retraceNavBar()
      .interactiveDismissDisabled(!isFinished)
    }
    .onChange(of: viewModel.phase) { _, newPhase in
      if case let .ready(procedureId) = newPhase {
        onComplete(procedureId)
      }
    }
  }

  @ViewBuilder
  private var phaseContent: some View {
    switch viewModel.phase {
    case .uploading:
      VStack(spacing: Spacing.xl) {
        ProgressView()
          .scaleEffect(1.5)
          .tint(.textPrimary)
        Text("Uploading manual…")
          .font(.retraceHeadline)
          .foregroundColor(.textPrimary)
        Text("Sending the PDF to the server.")
          .font(.retraceBody)
          .foregroundColor(.textSecondary)
          .multilineTextAlignment(.center)
      }
    case .analyzing:
      VStack(spacing: Spacing.xl) {
        ProgressView()
          .scaleEffect(1.5)
          .tint(.textPrimary)
        Text("Gemini is reading your manual…")
          .font(.retraceHeadline)
          .foregroundColor(.textPrimary)
        Text("This usually takes 30–90 seconds.")
          .font(.retraceBody)
          .foregroundColor(.textSecondary)
          .multilineTextAlignment(.center)
      }
    case .ready:
      VStack(spacing: Spacing.xl) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 56))
          .foregroundColor(.semanticSuccess)
        Text("Manual imported.")
          .font(.retraceHeadline)
          .foregroundColor(.textPrimary)
      }
    case .failed(let message):
      VStack(spacing: Spacing.xl) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 48))
          .foregroundColor(.semanticError)
        Text("Import failed")
          .font(.retraceHeadline)
          .foregroundColor(.textPrimary)
        Text(message)
          .font(.retraceBody)
          .foregroundColor(.textSecondary)
          .multilineTextAlignment(.center)
      }
    case .idle:
      EmptyView()
    }
  }

  @ViewBuilder
  private var actionRow: some View {
    switch viewModel.phase {
    case .analyzing:
      Button(action: onSendToBackground) {
        Text("Keep working in the background")
          .font(.retraceFace(.semibold, size: 16))
          .foregroundColor(.textPrimary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, Spacing.lg)
          .background(Color.surfaceRaised)
          .cornerRadius(Radius.md)
      }
    case .failed:
      VStack(spacing: Spacing.md) {
        Button(action: onRetry) {
          Text("Try Again")
            .font(.retraceFace(.semibold, size: 17))
            .foregroundColor(.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.lg)
            .background(Color.appPrimary)
            .cornerRadius(Radius.md)
        }
        Button(action: onDismiss) {
          Text("Close")
            .font(.retraceBody)
            .foregroundColor(.textSecondary)
            .padding(.vertical, Spacing.md)
        }
      }
    default:
      EmptyView()
    }
  }

  private var isFinished: Bool {
    switch viewModel.phase {
    case .ready, .failed: return true
    default: return false
    }
  }
}
