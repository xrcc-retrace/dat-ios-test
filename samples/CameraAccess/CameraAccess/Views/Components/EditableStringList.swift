import SwiftUI

struct EditableStringList: View {
  let title: String
  @Binding var items: [String]
  let accentColor: Color
  let placeholder: String

  @State private var editingIndex: Int?
  @FocusState private var focusedIndex: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text(title)
        .font(Font.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)
        .textCase(.uppercase)

      ForEach(Array(items.enumerated()), id: \.offset) { index, _ in
        HStack(spacing: Spacing.md) {
          Button {
            items.remove(at: index)
          } label: {
            Image(systemName: "minus.circle.fill")
              .foregroundColor(.semanticError)
              .font(.system(size: 18))
          }

          TextField(placeholder, text: Binding(
            get: { items.indices.contains(index) ? items[index] : "" },
            set: { if items.indices.contains(index) { items[index] = $0 } }
          ))
            .font(.retraceCallout)
            .foregroundColor(.textPrimary)
            .focused($focusedIndex, equals: index)
            .padding(10)
            .background(Color.surfaceRaised)
            .cornerRadius(Radius.sm)
        }
      }

      Button {
        items.append("")
        focusedIndex = items.count - 1
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "plus.circle.fill")
            .font(.system(size: 18))
          Text("Add \(title.lowercased().hasSuffix("s") ? String(title.dropLast()) : title)")
            .font(.retraceFace(.medium, size: 16))
        }
        .foregroundColor(accentColor)
      }
      .padding(.top, Spacing.xs)
    }
  }
}
