import Foundation

@MainActor
class WorkflowListViewModel: ObservableObject {
  @Published var procedures: [ProcedureListItem] = []
  @Published var isLoading = false
  @Published var errorMessage: String?

  private let api = ProcedureAPIService()

  /// While any row is `status == "processing"` we run a background task
  /// that re-fetches every 5 s with `forceRefresh: true`. The card
  /// auto-flips from "Analyzing…" to the real procedure as soon as the
  /// server commits — no manual pull-to-refresh required. The task
  /// cancels itself when no rows are processing and re-arms whenever a
  /// fresh fetch surfaces a new processing row.
  private var pollingTask: Task<Void, Never>?
  private static let pollingInterval: UInt64 = 5_000_000_000  // 5 s in ns

  /// `forceRefresh: true` is the pull-to-refresh path — bypasses URLCache so a
  /// just-uploaded procedure shows up immediately. Default re-entry uses cache
  /// for instant tab switching.
  func fetchProcedures(forceRefresh: Bool = false) async {
    isLoading = true
    errorMessage = nil
    do {
      procedures = try await api.fetchProcedures(forceRefresh: forceRefresh)
      ensurePollingMatchesState()
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  func deleteProcedure(id: String) async {
    do {
      try await api.deleteProcedure(id: id)
      procedures.removeAll { $0.id == id }
      ensurePollingMatchesState()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  var totalStepCount: Int {
    procedures.compactMap(\.stepCount).reduce(0, +)
  }

  /// Start polling iff there's at least one processing row, stop iff
  /// there isn't. Idempotent — safe to call after every state change.
  private func ensurePollingMatchesState() {
    let anyProcessing = procedures.contains { $0.status == "processing" }
    if anyProcessing {
      if pollingTask == nil {
        pollingTask = Task { [weak self] in
          await self?.pollLoop()
        }
      }
    } else {
      pollingTask?.cancel()
      pollingTask = nil
    }
  }

  private func pollLoop() async {
    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: Self.pollingInterval)
      guard !Task.isCancelled else { return }
      do {
        procedures = try await api.fetchProcedures(forceRefresh: true)
      } catch {
        // Quietly swallow — next tick will retry. Don't surface
        // transient network errors to the UI during background polling.
      }
      // If nothing's processing anymore, exit the loop and clear the
      // task handle so it can be restarted later if needed.
      if !procedures.contains(where: { $0.status == "processing" }) {
        pollingTask = nil
        return
      }
    }
  }

  deinit {
    pollingTask?.cancel()
  }
}
