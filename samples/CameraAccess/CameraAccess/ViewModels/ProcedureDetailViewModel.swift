import Foundation

@MainActor
class ProcedureDetailViewModel: ObservableObject {
  @Published var procedure: ProcedureResponse?
  @Published var isLoading = false
  @Published var errorMessage: String?
  @Published var expandedStep: Int?
  @Published var showDeleteConfirmation = false

  private let api = ProcedureAPIService()

  var serverBaseURL: String { api.baseURL }

  func fetchProcedure(id: String) async {
    isLoading = true
    errorMessage = nil
    do {
      procedure = try await api.fetchProcedure(id: id)
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  func deleteProcedure() async -> Bool {
    guard let id = procedure?.id else { return false }
    do {
      try await api.deleteProcedure(id: id)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func toggleStep(_ stepNumber: Int) {
    if expandedStep == stepNumber {
      expandedStep = nil
    } else {
      expandedStep = stepNumber
    }
  }
}
