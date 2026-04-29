import Foundation

@MainActor
class LibraryViewModel: ObservableObject {
  @Published var savedProcedures: [ProcedureResponse] = []
  @Published var isLoading = false

  private let api = ProcedureAPIService()

  /// Default re-entry uses URLCache so the previously-loaded list shows
  /// instantly without a spinner flash. Pass `forceRefresh: true` to
  /// bypass the cache and revalidate every entry.
  func loadSaved(ids: Set<String>, forceRefresh: Bool = false) async {
    if forceRefresh || savedProcedures.isEmpty {
      isLoading = true
    }
    let results: [ProcedureResponse] = await withTaskGroup(of: ProcedureResponse?.self) { group in
      for id in ids {
        group.addTask { [api] in
          try? await api.fetchProcedure(id: id, forceRefresh: forceRefresh)
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
