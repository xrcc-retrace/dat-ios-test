import Foundation

@MainActor
class DiscoverViewModel: ObservableObject {
  @Published var procedures: [ProcedureListItem] = []
  @Published var isLoading = false
  @Published var errorMessage: String?
  @Published var searchQuery = ""
  @Published var selectedCategory = "All"

  private let api = ProcedureAPIService()

  let categories = ["All", "Coffee Machines", "Electrical", "Assembly", "Maintenance", "Cleaning"]

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

  var filteredProcedures: [ProcedureListItem] {
    var result = procedures

    // Filter by search query
    if !searchQuery.isEmpty {
      let query = searchQuery.lowercased()
      result = result.filter {
        $0.title.lowercased().contains(query) ||
        $0.description.lowercased().contains(query)
      }
    }

    // Category filtering would go here when procedures have category tags
    // For now, "All" shows everything

    return result
  }
}
