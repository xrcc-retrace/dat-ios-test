import Foundation

@MainActor
class ProcedureDetailViewModel: ObservableObject {
  @Published var procedure: ProcedureResponse?
  @Published var isLoading = false
  @Published var errorMessage: String?
  @Published var showDeleteConfirmation = false

  private let api = ProcedureAPIService()

  var serverBaseURL: String { api.baseURL }

  /// `forceRefresh: true` is the pull-to-refresh path. Default re-entry
  /// keeps the cached procedure visible while quietly revalidating, so
  /// re-opening a detail view doesn't flash a spinner.
  func fetchProcedure(id: String, forceRefresh: Bool = false) async {
    let hadCachedDetail = procedure?.id == id
    if forceRefresh || !hadCachedDetail {
      isLoading = true
    }
    errorMessage = nil
    do {
      procedure = try await api.fetchProcedure(id: id, forceRefresh: forceRefresh)
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
}
