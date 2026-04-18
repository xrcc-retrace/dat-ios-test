import Foundation

@MainActor
class LocalProgressStore: ObservableObject {
  @Published var savedProcedureIDs: Set<String> = []
  @Published var sessionHistory: [SessionRecord] = []

  private let savedKey = "savedProcedureIDs"
  private let historyKey = "sessionHistory"

  init() {
    loadSaved()
    loadHistory()
  }

  // MARK: - Bookmarks

  func toggleSaved(_ procedureId: String) {
    if savedProcedureIDs.contains(procedureId) {
      savedProcedureIDs.remove(procedureId)
    } else {
      savedProcedureIDs.insert(procedureId)
    }
    persistSaved()
  }

  func isSaved(_ procedureId: String) -> Bool {
    savedProcedureIDs.contains(procedureId)
  }

  // MARK: - Session History

  func startSession(
    procedureId: String,
    procedureTitle: String,
    totalSteps: Int,
    stepsCompleted: Int = 0
  ) -> SessionRecord {
    let record = SessionRecord(
      id: UUID().uuidString,
      procedureId: procedureId,
      procedureTitle: procedureTitle,
      startedAt: Date(),
      completedAt: nil,
      stepsCompleted: stepsCompleted,
      totalSteps: totalSteps,
      status: .inProgress
    )
    sessionHistory.insert(record, at: 0)
    persistHistory()
    return record
  }

  func updateSession(id: String, stepsCompleted: Int, status: SessionStatus) {
    guard let index = sessionHistory.firstIndex(where: { $0.id == id }) else { return }
    sessionHistory[index].stepsCompleted = stepsCompleted
    sessionHistory[index].status = status
    if status == .completed {
      sessionHistory[index].completedAt = Date()
    }
    persistHistory()
  }

  func inProgressSession(for procedureId: String) -> SessionRecord? {
    sessionHistory.first { $0.procedureId == procedureId && $0.status == .inProgress }
  }

  var anyInProgressSession: SessionRecord? {
    sessionHistory.first { $0.status == .inProgress }
  }

  // MARK: - Session History — Delete

  func deleteSessions(ids: Set<String>) {
    guard !ids.isEmpty else { return }
    sessionHistory.removeAll { ids.contains($0.id) }
    persistHistory()
  }

  func clearAllHistory() {
    guard !sessionHistory.isEmpty else { return }
    sessionHistory.removeAll()
    persistHistory()
  }

  // MARK: - Stats

  var completedCount: Int {
    sessionHistory.filter { $0.status == .completed }.count
  }

  var totalStepsMastered: Int {
    sessionHistory.filter { $0.status == .completed }.reduce(0) { $0 + $1.totalSteps }
  }

  var totalTimeTraining: TimeInterval {
    sessionHistory.compactMap { record -> TimeInterval? in
      guard let end = record.completedAt else { return nil }
      return end.timeIntervalSince(record.startedAt)
    }.reduce(0, +)
  }

  func activeDays(last n: Int) -> [Bool] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    return (0..<n).reversed().map { dayOffset in
      guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { return false }
      return sessionHistory.contains { record in
        calendar.isDate(record.startedAt, inSameDayAs: date)
      }
    }
  }

  // MARK: - Persistence

  private func loadSaved() {
    if let data = UserDefaults.standard.data(forKey: savedKey),
       let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
      savedProcedureIDs = ids
    }
  }

  private func persistSaved() {
    if let data = try? JSONEncoder().encode(savedProcedureIDs) {
      UserDefaults.standard.set(data, forKey: savedKey)
    }
  }

  private func loadHistory() {
    if let data = UserDefaults.standard.data(forKey: historyKey),
       let records = try? JSONDecoder().decode([SessionRecord].self, from: data) {
      sessionHistory = records
    }
  }

  private func persistHistory() {
    if let data = try? JSONEncoder().encode(sessionHistory) {
      UserDefaults.standard.set(data, forKey: historyKey)
    }
  }
}
