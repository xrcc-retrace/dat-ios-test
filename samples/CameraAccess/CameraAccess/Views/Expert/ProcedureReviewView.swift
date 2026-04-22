import SwiftUI

struct ProcedureReviewView: View {
  let initialProcedure: ProcedureResponse
  let serverBaseURL: String
  let onConfirmed: () -> Void
  let onCanceled: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var description: String
  @State private var steps: [ProcedureStepResponse]
  @State private var isCommitting = false
  @State private var errorMessage: String?
  @State private var showDiscardDialog = false
  @State private var draggingStepNumber: Int?
  @State private var dragTranslation: CGFloat = 0
  @State private var rowHeight: CGFloat = 96

  private let api = ProcedureAPIService()

  init(
    initialProcedure: ProcedureResponse,
    serverBaseURL: String,
    onConfirmed: @escaping () -> Void,
    onCanceled: @escaping () -> Void = {}
  ) {
    self.initialProcedure = initialProcedure
    self.serverBaseURL = serverBaseURL
    self.onConfirmed = onConfirmed
    self.onCanceled = onCanceled
    self._title = State(initialValue: initialProcedure.title)
    self._description = State(initialValue: initialProcedure.description)
    self._steps = State(
      initialValue: initialProcedure.steps.sorted { $0.stepNumber < $1.stepNumber }
    )
  }

  var body: some View {
    RetraceScreen {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.section) {
          headerCard
          stepsSection
          if let errorMessage {
            Text(errorMessage)
              .font(.retraceSubheadline)
              .foregroundColor(.semanticError)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.xl)
      }
    }
    .navigationTitle("Review Workflow")
    .navigationBarTitleDisplayMode(.inline)
    .retraceNavBar()
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Cancel") { handleCancelTap() }
          .foregroundColor(.textSecondary)
          .disabled(isCommitting)
      }
      ToolbarItem(placement: .topBarTrailing) {
        confirmPill
      }
    }
    .confirmationDialog(
      "Discard workflow edits?",
      isPresented: $showDiscardDialog,
      titleVisibility: .visible
    ) {
      Button("Discard changes", role: .destructive) {
        onCanceled()
        dismiss()
      }
      Button("Keep editing", role: .cancel) {}
    } message: {
      Text(
        "Your edits to the title, description, step order, and step content will be lost. The workflow will remain with the AI's original output."
      )
    }
    .interactiveDismissDisabled(hasAnyChanges || isCommitting)
  }

  // MARK: - Header card

  @ViewBuilder
  private var headerCard: some View {
    VStack(alignment: .leading, spacing: Spacing.xl) {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text("TITLE")
          .font(.retraceOverline)
          .tracking(0.5)
          .foregroundColor(.textSecondary)
        TextField("Workflow title", text: $title, axis: .vertical)
          .font(.retraceTitle2)
          .foregroundColor(.textPrimary)
          .lineLimit(1...3)
        Rectangle()
          .frame(height: 1)
          .foregroundColor(.borderSubtle)
      }

      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text("DESCRIPTION")
          .font(.retraceOverline)
          .tracking(0.5)
          .foregroundColor(.textSecondary)
        TextEditor(text: $description)
          .font(.retraceBody)
          .foregroundColor(.textSecondary)
          .scrollContentBackground(.hidden)
          .frame(minHeight: 60, maxHeight: 160)
        Rectangle()
          .frame(height: 1)
          .foregroundColor(.borderSubtle)
      }

      metadataStrip
    }
    .padding(Spacing.xl)
    .background(Color.surfaceBase)
    .cornerRadius(Radius.md)
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
  }

  @ViewBuilder
  private var metadataStrip: some View {
    HStack(spacing: Spacing.xl) {
      metadataItem(icon: "list.number", text: "\(steps.count) step\(steps.count == 1 ? "" : "s")")
      metadataItem(icon: "clock", text: formatDuration(totalDuration))
      if initialProcedure.sourceVideo != nil {
        metadataItem(icon: "video.fill", text: "From video")
      }
    }
  }

  @ViewBuilder
  private func metadataItem(icon: String, text: String) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: icon)
        .font(.retraceCaption1)
      Text(text)
        .font(.retraceCaption1)
    }
    .foregroundColor(.textTertiary)
  }

  // MARK: - Steps section

  @ViewBuilder
  private var stepsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      Text("STEPS · DRAG TO REORDER · TAP TO EDIT")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)

      VStack(spacing: Spacing.md) {
        ForEach(Array(steps.enumerated()), id: \.element.stepNumber) { index, step in
          ReviewStepRow(
            step: step,
            displayIndex: index + 1,
            isEdited: isStepEdited(step),
            isDragging: draggingStepNumber == step.stepNumber,
            serverBaseURL: serverBaseURL,
            procedureId: initialProcedure.id,
            onLocalSave: { updated in mergeStepEdit(updated) },
            onDragChanged: { translation in handleDrag(of: step, index: index, translation: translation) },
            onDragEnded: { handleDragEnded() },
            onHeightMeasured: { h in if draggingStepNumber == nil { rowHeight = h } }
          )
          .offset(y: draggingStepNumber == step.stepNumber ? dragTranslation : 0)
          .zIndex(draggingStepNumber == step.stepNumber ? 1 : 0)
          .animation(
            .spring(response: 0.32, dampingFraction: 0.78),
            value: steps.map(\.stepNumber)
          )
        }
      }
    }
  }

  // MARK: - Confirm button

  @ViewBuilder
  private var confirmPill: some View {
    Button {
      Task { await confirm() }
    } label: {
      HStack(spacing: Spacing.xs) {
        if isCommitting {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: .white))
            .scaleEffect(0.8)
        } else {
          Image(systemName: "checkmark")
            .font(.retraceCaption1)
            .fontWeight(.bold)
        }
        Text(isCommitting ? "Saving" : "Confirm")
          .font(.retraceCallout)
          .fontWeight(.semibold)
      }
      .foregroundColor(.white)
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.sm)
      .background(Color.appPrimary)
      .clipShape(Capsule())
      .opacity(isCommitting ? 0.85 : 1.0)
    }
    .disabled(isCommitting)
  }

  // MARK: - Drag logic

  private func handleDrag(of step: ProcedureStepResponse, index: Int, translation: CGFloat) {
    if draggingStepNumber != step.stepNumber {
      draggingStepNumber = step.stepNumber
    }
    dragTranslation = translation

    // Compute target index based on translation and row height + spacing.
    let slot = rowHeight + Spacing.md
    guard slot > 0 else { return }
    let delta = Int((translation / slot).rounded())
    let target = max(0, min(steps.count - 1, index + delta))
    if target != index {
      withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
        steps.move(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
      }
      // The moved row is now at `target`; reset translation so it doesn't appear to jump.
      // Recompute translation relative to new slot position.
      dragTranslation = translation - CGFloat(target - index) * slot
    }
  }

  private func handleDragEnded() {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
      dragTranslation = 0
    }
    draggingStepNumber = nil
  }

  // MARK: - Step merge

  private func mergeStepEdit(_ updated: ProcedureStepResponse) {
    if let idx = steps.firstIndex(where: { $0.stepNumber == updated.stepNumber }) {
      steps[idx] = updated
    }
  }

  // MARK: - Diffs

  private func isStepEdited(_ step: ProcedureStepResponse) -> Bool {
    guard let original = initialProcedure.steps.first(where: { $0.stepNumber == step.stepNumber })
    else { return false }
    return step.title != original.title
      || step.description != original.description
      || step.tips != original.tips
      || step.warnings != original.warnings
      || step.errorCriteria != original.errorCriteria
  }

  private var changedSteps: [ProcedureStepResponse] {
    steps.filter { isStepEdited($0) }
  }

  private var originalOrder: [Int] {
    initialProcedure.steps.sorted { $0.stepNumber < $1.stepNumber }.map(\.stepNumber)
  }

  private var currentOrder: [Int] { steps.map(\.stepNumber) }

  private var hasProcedureLevelChanges: Bool {
    title != initialProcedure.title
      || description != initialProcedure.description
      || currentOrder != originalOrder
  }

  private var hasAnyChanges: Bool {
    hasProcedureLevelChanges || !changedSteps.isEmpty
  }

  // MARK: - Commit

  private func confirm() async {
    isCommitting = true
    errorMessage = nil
    do {
      // 1. Per-step content updates first, using original step_numbers (reorder hasn't landed server-side yet).
      for step in changedSteps {
        guard let original = initialProcedure.steps.first(where: { $0.stepNumber == step.stepNumber })
        else { continue }
        let update = StepUpdateRequest(
          title: step.title != original.title ? step.title : nil,
          description: step.description != original.description ? step.description : nil,
          tips: step.tips != original.tips ? step.tips : nil,
          warnings: step.warnings != original.warnings ? step.warnings : nil,
          errorCriteria: step.errorCriteria != original.errorCriteria ? step.errorCriteria : nil
        )
        _ = try await api.updateStep(
          procedureId: initialProcedure.id,
          stepNumber: step.stepNumber,
          update: update
        )
      }
      // 2. Procedure-level update last: title, description, and step reorder.
      if hasProcedureLevelChanges {
        let update = ProcedureUpdateRequest(
          title: title != initialProcedure.title ? title : nil,
          description: description != initialProcedure.description ? description : nil,
          stepOrder: currentOrder != originalOrder ? currentOrder : nil
        )
        _ = try await api.updateProcedure(id: initialProcedure.id, update: update)
      }
      onConfirmed()
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
      isCommitting = false
    }
  }

  // MARK: - Cancel

  private func handleCancelTap() {
    if hasAnyChanges {
      showDiscardDialog = true
    } else {
      onCanceled()
      dismiss()
    }
  }

  // MARK: - Helpers

  private var totalDuration: Double {
    steps.map(\.timestampEnd).max() ?? initialProcedure.totalDuration
  }

  private func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let mins = total / 60
    let secs = total % 60
    return String(format: "%d:%02d", mins, secs)
  }
}

// MARK: - Step row

private struct ReviewStepRow: View {
  let step: ProcedureStepResponse
  let displayIndex: Int
  let isEdited: Bool
  let isDragging: Bool
  let serverBaseURL: String
  let procedureId: String
  let onLocalSave: (ProcedureStepResponse) -> Void
  let onDragChanged: (CGFloat) -> Void
  let onDragEnded: () -> Void
  let onHeightMeasured: (CGFloat) -> Void

  @GestureState private var isPressed: Bool = false

  var body: some View {
    HStack(spacing: 0) {
      dragHandle
      NavigationLink {
        StepEditView(
          procedureId: procedureId,
          step: step,
          localSaveHandler: onLocalSave
        )
      } label: {
        cardBody
      }
      .buttonStyle(.plain)
    }
    .background(
      GeometryReader { proxy in
        Color.clear.preference(key: RowHeightKey.self, value: proxy.size.height)
      }
    )
    .onPreferenceChange(RowHeightKey.self) { onHeightMeasured($0) }
    .background(Color.surfaceBase)
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md)
        .stroke(isDragging ? Color.appPrimary.opacity(0.8) : Color.borderSubtle, lineWidth: 1)
    )
    .cornerRadius(Radius.md)
    .shadow(color: Color.black.opacity(isDragging ? 0.25 : 0), radius: 12, x: 0, y: 6)
    .scaleEffect(isDragging ? 1.02 : 1.0)
  }

  @ViewBuilder
  private var dragHandle: some View {
    ZStack {
      Image(systemName: "line.3.horizontal")
        .font(.retraceCallout)
        .foregroundColor(isDragging ? .appPrimary : .textTertiary)
    }
    .frame(width: 44, height: 44)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 4, coordinateSpace: .global)
        .onChanged { value in onDragChanged(value.translation.height) }
        .onEnded { _ in onDragEnded() }
    )
    .accessibilityLabel("Reorder step \(displayIndex)")
    .accessibilityHint("Press and drag up or down to move this step")
  }

  @ViewBuilder
  private var cardBody: some View {
    HStack(alignment: .top, spacing: Spacing.lg) {
      stepNumberChip
      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
          Text(step.title)
            .font(.retraceHeadline)
            .foregroundColor(.textPrimary)
            .lineLimit(1)
          if isEdited {
            editedBadge
          }
          Spacer(minLength: 0)
        }
        Text(step.description)
          .font(.retraceCaption1)
          .foregroundColor(.textSecondary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
        if hasBadges {
          badgeRow
        }
      }
      Image(systemName: "chevron.right")
        .font(.retraceCaption1)
        .foregroundColor(.textTertiary)
        .padding(.top, 4)
    }
    .padding(.vertical, Spacing.lg)
    .padding(.trailing, Spacing.xl)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var stepNumberChip: some View {
    Text("\(displayIndex)")
      .font(.retraceCaption1)
      .fontWeight(.bold)
      .foregroundColor(.appPrimary)
      .frame(width: 26, height: 26)
      .background(Color.appPrimary.opacity(0.14))
      .clipShape(Circle())
  }

  @ViewBuilder
  private var editedBadge: some View {
    Text("edited")
      .font(.retraceCaption2)
      .foregroundColor(.appPrimary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, 2)
      .background(Color.appPrimary.opacity(0.14))
      .clipShape(Capsule())
  }

  private var hasBadges: Bool {
    step.clipUrl != nil || !step.tips.isEmpty || !step.warnings.isEmpty || !step.errorCriteria.isEmpty
  }

  @ViewBuilder
  private var badgeRow: some View {
    HStack(spacing: Spacing.sm) {
      if step.clipUrl != nil {
        badge(icon: "video.fill", text: formatClipDuration(), color: .textSecondary, bg: .surfaceRaised)
      }
      if !step.tips.isEmpty {
        badge(icon: "lightbulb.fill", text: "\(step.tips.count)", color: .semanticInfo, bg: Color.semanticInfo.opacity(0.15))
      }
      if !step.warnings.isEmpty {
        badge(icon: "exclamationmark.triangle.fill", text: "\(step.warnings.count)", color: .appPrimary, bg: Color.appPrimary.opacity(0.15))
      }
      if !step.errorCriteria.isEmpty {
        badge(icon: "flag.fill", text: "\(step.errorCriteria.count)", color: .semanticError, bg: Color.semanticError.opacity(0.15))
      }
    }
  }

  @ViewBuilder
  private func badge(icon: String, text: String, color: Color, bg: Color) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .semibold))
      Text(text)
        .font(.retraceCaption2)
        .fontWeight(.semibold)
    }
    .foregroundColor(color)
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, 3)
    .background(bg)
    .clipShape(Capsule())
  }

  private func formatClipDuration() -> String {
    let span = max(0, step.timestampEnd - step.timestampStart)
    let total = Int(span.rounded())
    let mins = total / 60
    let secs = total % 60
    return String(format: "%d:%02d", mins, secs)
  }
}

// MARK: - Preference key for row height

private struct RowHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 96
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    let next = nextValue()
    if next > 0 { value = next }
  }
}
