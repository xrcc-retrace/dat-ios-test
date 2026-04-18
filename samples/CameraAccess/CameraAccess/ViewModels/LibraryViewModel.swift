import Foundation

@MainActor
class LibraryViewModel: ObservableObject {
  @Published var savedProcedures: [ProcedureResponse] = []
  @Published var isLoading = false

  private let api = ProcedureAPIService()

  func loadSaved(ids: Set<String>) async {
    isLoading = true
    let results: [ProcedureResponse] = await withTaskGroup(of: ProcedureResponse?.self) { group in
      for id in ids {
        group.addTask { [api] in
          try? await api.fetchProcedure(id: id)
        }
      }
      var collected: [ProcedureResponse] = []
      for await procedure in group {
        if let procedure { collected.append(procedure) }
      }
      return collected
    }
    savedProcedures = results
    isLoading = false
  }
}
