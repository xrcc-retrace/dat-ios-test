import SwiftUI

struct ProcedureEditView: View {
  let procedure: ProcedureResponse
  let onSaved: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var description: String
  @State private var stepOrder: [ProcedureStepResponse]
  @State private var isSaving = false
  @State private var errorMessage: String?

  private let api = ProcedureAPIService()

  init(procedure: ProcedureResponse, onSaved: @escaping () -> Void) {
    self.procedure = procedure
    self.onSaved = onSaved
    self._title = State(initialValue: procedure.title)
    self._description = State(initialValue: procedure.description)
    self._stepOrder = State(initialValue: procedure.steps.sorted { $0.stepNumber < $1.stepNumber })
  }

  private var hasChanges: Bool {
    title != procedure.title ||
    description != procedure.description ||
    stepOrder.map(\.stepNumber) != procedure.steps.sorted(by: { $0.stepNumber < $1.stepNumber }).map(\.stepNumber)
  }

  var body: some View {
    RetraceScreen {

      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.screenPadding) {
          // Title
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text("TITLE")
              .font(.retraceOverline)
              .tracking(0.5)
              .foregroundColor(.textSecondary)

            TextField("Procedure title", text: $title)
              .font(.retraceHeadline)
              .foregroundColor(.textPrimary)
              .padding(Spacing.lg)
              .background(Color.surfaceRaised)
              .cornerRadius(Radius.md)
              .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                  .stroke(Color.borderSubtle, lineWidth: 1)
              )
          }

          // Description
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text("DESCRIPTION")
              .font(.retraceOverline)
              .tracking(0.5)
              .foregroundColor(.textSecondary)

            TextEditor(text: $description)
              .font(.retraceCallout)
              .foregroundColor(.textPrimary)
              .scrollContentBackground(.hidden)
              .frame(minHeight: 80)
              .padding(Spacing.lg)
              .background(Color.surfaceRaised)
              .cornerRadius(Radius.md)
              .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                  .stroke(Color.borderSubtle, lineWidth: 1)
              )
          }

          // Step order
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text("STEP ORDER")
              .font(.retraceOverline)
              .tracking(0.5)
              .foregroundColor(.textSecondary)

            ForEach(stepOrder) { step in
              HStack(spacing: Spacing.lg) {
                Image(systemName: "line.3.horizontal")
                  .foregroundColor(.textTertiary)
                  .font(.retraceCallout)

                Text("\(step.stepNumber).")
                  .font(.retraceFace(.semibold, size: 16))
                  .foregroundColor(.textPrimary)

                Text(step.title)
                  .font(.retraceCallout)
                  .foregroundColor(.textPrimary)
                  .lineLimit(1)

                Spacer()
              }
              .padding(Spacing.lg)
              .background(Color.surfaceBase)
              .cornerRadius(Radius.sm)
            }
            .onMove { from, to in
              stepOrder.move(fromOffsets: from, toOffset: to)
            }
          }

          // Error
          if let error = errorMessage {
            Text(error)
              .font(.retraceSubheadline)
              .foregroundColor(.semanticError)
          }
        }
        .padding(Spacing.screenPadding)
      }
    }
    .navigationTitle("Edit Workflow")
    .navigationBarTitleDisplayMode(.inline)
    .retraceNavBar()
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Cancel") { dismiss() }
          .foregroundColor(.textPrimary)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Save") {
          Task { await save() }
        }
        .foregroundColor(hasChanges ? .textPrimary : .textTertiary)
        .disabled(!hasChanges || isSaving)
      }
    }
  }

  private func save() async {
    isSaving = true
    errorMessage = nil

    let update = ProcedureUpdateRequest(
      title: title != procedure.title ? title : nil,
      description: description != procedure.description ? description : nil,
      stepOrder: stepOrder.map(\.stepNumber) != procedure.steps.sorted(by: { $0.stepNumber < $1.stepNumber }).map(\.stepNumber) ? stepOrder.map(\.stepNumber) : nil
    )

    do {
      _ = try await api.updateProcedure(id: procedure.id, update: update)
      onSaved()
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
    isSaving = false
  }
}
