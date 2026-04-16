import Foundation

@MainActor
class WorkflowListViewModel: ObservableObject {
  @Published var procedures: [ProcedureListItem] = []
  @Published var isLoading = false
  @Published var errorMessage: String?

  private let api = ProcedureAPIService()

  func fetchProcedures() async {
    isLoading = true
    errorMessage = nil
    do {
      procedures = try await api.fetchProcedures()
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  func deleteProcedure(id: String) async {
    do {
      try await api.deleteProcedure(id: id)
      procedures.removeAll { $0.id == id }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  var totalStepCount: Int {
    procedures.compactMap(\.stepCount).reduce(0, +)
  }
}
