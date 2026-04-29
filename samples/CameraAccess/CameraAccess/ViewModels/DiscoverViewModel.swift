import Foundation

@MainActor
class DiscoverViewModel: ObservableObject {
  @Published var procedures: [ProcedureListItem] = []
  @Published var isLoading = false
  @Published var errorMessage: String?
  @Published var searchQuery = ""
  @Published var selectedCategory = "All"

  private let api = ProcedureAPIService()

  // Canonical chip list — must stay in sync with the backend's
  // ProcedureCategory Literal in models/procedure.py. "All" is a UI
  // affordance only (server never assigns it). Server defaults to "Other"
  // for procedures Gemini couldn't classify or that predate the field.
  let categories = [
    "All",
    "Assembly",
    "Electrical",
    "Calibration",
    "Maintenance",
    "Repair",
    "Inspection",
    "Other",
  ]

  /// `forceRefresh: true` is the pull-to-refresh path — show the spinner
  /// and bypass URLCache. The `.task` path on view appear leaves the
  /// existing list visible and replaces it silently when the response
  /// returns, so re-entering Discover doesn't flash a spinner.
  func fetchProcedures(forceRefresh: Bool = false) async {
    let hadCachedList = !procedures.isEmpty
    if forceRefresh || !hadCachedList {
      isLoading = true
    }
    errorMessage = nil
    do {
      procedures = try await api.fetchProcedures(forceRefresh: forceRefresh)
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

    // Category filter — "All" is a no-op; otherwise match the server-
    // assigned category, treating nil/empty as "Other" so legacy rows
    // still surface in the catch-all chip rather than vanishing entirely.
    if selectedCategory != "All" {
      result = result.filter {
        let c = ($0.category?.isEmpty == false ? $0.category : nil) ?? "Other"
        return c == selectedCategory
      }
    }

    return result
  }
}
