import Combine
import MWDATCamera
import MWDATCore
import SwiftUI

enum StepNavigationDirection: Equatable {
  case next
  case previous
}

enum HUDStepTransitionState: Equatable {
  case idle
  case syncing(direction: StepNavigationDirection, targetStepNumber: Int?)
}

/// Learner-mode coaching session. Inherits the shared Gemini Live
/// machinery from `GeminiLiveSessionBase` and plugs in coaching-specific
/// behavior via template-method overrides.
///
/// Mode-specific state: procedure-bound step tracking, `showPiP` reference
/// clips, heartbeat scheduler (`[check]` markers on silence to unblock
/// Gemini 3.1 Flash's VAD-gated video evaluation), progress-store
/// integration, session-duration display. Everything else — audio, camera
/// (both transports), WebSocket, tool-call forwarding, transcripts,
/// barge-in, session resumption — lives on the base.
@MainActor
class CoachingSessionViewModel: GeminiLiveSessionBase {

  // MARK: - Mode-specific published state

  @Published var currentStepIndex = 0
  @Published var isCompleted = false
  @Published var showPiP = false
  @Published private(set) var hudStepTransitionState: HUDStepTransitionState = .idle

  // MARK: - Inputs

  private let procedure: ProcedureResponse
  private let _transport: CaptureTransport
  private var sessionStartTime: Date?
  private var sessionRecordId: String?
  private weak var progressStore: LocalProgressStore?
  private var pendingStartingStep: Int?

  // MARK: - Heartbeat
  //
  // Design (see .claude/plans/snappy-singing-harbor.md):
  //   Primary path — onTurnComplete → Task.sleep(5s) → send [check]. Matches
  //   the sanctioned `setTimeout` form from live-api-web-console#20.
  //   Fallback — if the model stays silent on a [check] (the desired default
  //   when nothing's wrong, since no onTurnComplete fires in that case), a
  //   second Task.sleep reschedules so we don't stall forever.
  //
  // These are coaching-only: the marker prompts Gemini to evaluate video on
  // silent audio. Diagnostic / future modes don't need this signal.

  private var heartbeatTask: Task<Void, Never>?
  private var heartbeatEnabled = false
  private static let heartbeatIntervalSeconds: UInt64 = 5
  private static let heartbeatMarker = "[check]"

  // MARK: - Computed

  var currentStep: ProcedureStepResponse? {
    guard currentStepIndex < procedure.steps.count else { return nil }
    return procedure.steps.sorted { $0.stepNumber < $1.stepNumber }[currentStepIndex]
  }

  /// Frozen total duration, captured the moment the session completes so the
  /// "Procedure Complete" panel doesn't keep ticking.
  private var frozenSessionDuration: TimeInterval?

  var formattedSessionDuration: String {
    let elapsed: TimeInterval
    if let frozen = frozenSessionDuration {
      elapsed = frozen
    } else if let start = sessionStartTime {
      elapsed = Date().timeIntervalSince(start)
    } else {
      elapsed = 0
    }
    let mins = Int(elapsed) / 60
    let secs = Int(elapsed) % 60
    return String(format: "%d:%02d", mins, secs)
  }

  // MARK: - Init

  init(
    procedure: ProcedureResponse,
    wearables: WearablesInterface,
    serverBaseURL: String,
    transport: CaptureTransport = .glasses
  ) {
    self.procedure = procedure
    self._transport = transport
    super.init(wearables: wearables, serverBaseURL: serverBaseURL)
  }

  // MARK: - Lifecycle (public entry / exit)

  func startSession(progressStore: LocalProgressStore, startingStep: Int? = nil) {
    print("[Coaching] ── session STARTED (transport=\(_transport), procedure=\(procedure.id), startingStep=\(startingStep.map(String.init) ?? "nil"))")
    // Reset mode-specific state. Base fields are handled by
    // startGeminiLiveSession → stopGeminiLiveSession.
    // Server is 1-indexed, VM is 0-indexed. `startingStep == nil` means fresh
    // session at step 1 → index 0.
    let seededIndex = max(0, (startingStep ?? 1) - 1)
    currentStepIndex = seededIndex
    isCompleted = false
    frozenSessionDuration = nil
    showPiP = false
    hudStepTransitionState = .idle
    pendingStartingStep = startingStep

    self.progressStore = progressStore
    sessionStartTime = Date()
    let record = progressStore.startSession(
      procedureId: procedure.id,
      procedureTitle: procedure.title,
      totalSteps: procedure.steps.count,
      stepsCompleted: seededIndex
    )
    sessionRecordId = record.id

    Task {
      await startGeminiLiveSession()
    }
  }

  func endSession(progressStore: LocalProgressStore) {
    guard let recordId = sessionRecordId else { return }
    let status: SessionStatus = isCompleted ? .completed : .abandoned
    progressStore.updateSession(id: recordId, stepsCompleted: currentStepIndex, status: status)

    // Snapshot before stopGeminiLiveSession() nils sessionId, then fire the
    // DELETE in the background. Without this the server's in-memory _sessions
    // dict grows unboundedly — sessions are never cleaned up server-side
    // until the process restarts.
    let sidToDelete = sessionId
    let base = serverBaseURL
    if let sid = sidToDelete {
      Task.detached {
        await Self.deleteLearnerSession(sessionId: sid, serverBaseURL: base)
      }
    }

    stopGeminiLiveSession()
    stopCameraStream()
    print("[Coaching] ── session ENDED")
  }

  private static func deleteLearnerSession(sessionId: String, serverBaseURL: String) async {
    guard let url = URL(string: "\(serverBaseURL)/api/learner/session/\(sessionId)") else {
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.timeoutInterval = 5
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      let code = (response as? HTTPURLResponse)?.statusCode ?? -1
      if !(200...299).contains(code) {
        print("[Coaching] Session DELETE returned HTTP \(code)")
      }
    } catch {
      // Best-effort. Server's in-memory state will be lost on restart anyway.
      print("[Coaching] Session DELETE failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Base overrides (template hooks)

  override func mintSession() async throws -> SessionStartPayload {
    let autoAdvance = UserDefaults.standard.object(forKey: "autoAdvanceEnabled") as? Bool ?? true
    print("[Coaching] auto_advance = \(autoAdvance) (from UserDefaults)")
    let selectedVoice = UserDefaults.standard.string(forKey: "geminiVoice") ?? "Puck"
    print("[Coaching] voice = \(selectedVoice) (from UserDefaults)")

    let apiService = ProcedureAPIService()
    let response = try await apiService.startLearnerSession(
      procedureId: procedure.id,
      voice: selectedVoice,
      autoAdvance: autoAdvance,
      startingStep: pendingStartingStep
    )
    return SessionStartPayload(
      sessionId: response.sessionId,
      ephemeralToken: response.ephemeralToken
    )
  }

  override var toolCallURLSuffix: String {
    guard let sid = sessionId else { return "/api/learner/session//tool-call" }
    return "/api/learner/session/\(sid)/tool-call"
  }

  override var toolCallTimeoutSeconds: TimeInterval { 10 }

  override var introSeedText: String? { "Hi, I'm ready to begin." }

  override var transport: CaptureTransport { _transport }

  /// `.coaching` on glasses (allows HFP route), `.coachingPhoneOnly` on iPhone.
  override var audioSessionMode: AudioSessionMode {
    _transport == .iPhone ? .coachingPhoneOnly : .coaching
  }

  override func onConnectedExtra() {
    // Heartbeat arms on every .connected transition (including resumption
    // reconnects). scheduleNextHeartbeat cancels any prior tick before
    // starting, so this is safe to call more than once.
    heartbeatEnabled = true
    scheduleNextHeartbeat()
  }

  override func onTurnCompleteExtra() async {
    // Heartbeat cadence is anchored on turnComplete (the sanctioned pattern
    // from google-gemini/live-api-web-console#20). This fires ~5s after the
    // model finishes replying, naturally avoiding heartbeat-during-AI-speech
    // collisions.
    scheduleNextHeartbeat()
  }

  override func willStopGeminiLiveSession() {
    // Stop the heartbeat scheduler BEFORE the base drops Combine subs so
    // an in-flight Task.sleep can't wake up into a half-torn-down service.
    heartbeatEnabled = false
    heartbeatTask?.cancel()
    heartbeatTask = nil
  }

  override func handleToolCallExtras(name: String, args: [String: Any], result: [String: Any]) async {
    applyLearnerToolResult(name: name, args: args, result: result)
  }

  override func toolCallSummary(name: String, args: [String: Any], result: [String: Any]) -> String {
    switch name {
    case "advance_step":
      if let status = result["status"] as? String, status == "completed" {
        return "Procedure complete"
      }
      if let newStep = result["new_step"] as? Int,
         let title = result["step_title"] as? String {
        return "Advanced to step \(newStep): \(title)"
      }
      return "Advanced step"
    case "go_to_step":
      if let step = result["current_step"] as? Int,
         let title = result["step_title"] as? String {
        return "Jumped to step \(step): \(title)"
      }
      if let step = args["step_number"] as? Int {
        return "Jumped to step \(step)"
      }
      return "Jumped step"
    case "get_reference_clip":
      if let step = result["step_number"] as? Int {
        return "Showing reference clip for step \(step)"
      }
      return "Showing reference clip"
    default:
      return name
    }
  }

  override func contextSummaryForReconnect() async -> String? {
    guard let sid = sessionId else { return nil }
    do {
      return try await ProcedureAPIService().fetchContextSummary(sessionId: sid)
    } catch {
      print("[Coaching] Failed to fetch context summary: \(error)")
      return nil
    }
  }

  func navigateStepFromHUD(direction: StepNavigationDirection) async {
    guard hudStepTransitionState == .idle else { return }
    guard let sessionId else { return }

    let toolName: String
    let arguments: [String: Any]
    let targetStepNumber: Int?

    switch direction {
    case .next:
      toolName = "advance_step"
      arguments = [:]
      let predicted = currentStepIndex + 2
      targetStepNumber = predicted <= procedure.steps.count ? predicted : nil
    case .previous:
      guard currentStepIndex > 0 else { return }
      toolName = "go_to_step"
      arguments = ["step_number": currentStepIndex]
      targetStepNumber = currentStepIndex
    }

    hudStepTransitionState = .syncing(direction: direction, targetStepNumber: targetStepNumber)
    showPiP = false

    defer {
      hudStepTransitionState = .idle
    }

    let apiService = ProcedureAPIService()

    do {
      let result = try await apiService.invokeLearnerToolCall(
        sessionId: sessionId,
        toolName: toolName,
        arguments: arguments
      )
      applyLearnerToolResult(name: toolName, args: arguments, result: result)
      await syncGeminiAfterManualNavigation(direction: direction, result: result)
    } catch {
      print("[Coaching] Manual HUD navigation failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Heartbeat scheduling (coaching-only)

  private func scheduleNextHeartbeat() {
    guard heartbeatEnabled else { return }
    heartbeatTask?.cancel()
    heartbeatTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: Self.heartbeatIntervalSeconds * 1_000_000_000)
      guard !Task.isCancelled, let self = self, self.heartbeatEnabled else { return }
      // Safety gate: mic-initiated learner turn / tool call in flight / AI
      // still speaking means the next onTurnComplete will come and
      // re-schedule us. Skip this tick without firing.
      guard self.isGeminiReady,
            self.pendingToolCallIds.isEmpty,
            !self.isAISpeaking else {
        return
      }
      await self.sendHeartbeat()
      // Fallback in case Gemini stays silent (no onTurnComplete will fire).
      self.scheduleHeartbeatFallback()
    }
  }

  private func scheduleHeartbeatFallback() {
    heartbeatTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: Self.heartbeatIntervalSeconds * 1_000_000_000)
      guard !Task.isCancelled, let self = self, self.heartbeatEnabled else { return }
      self.scheduleNextHeartbeat()
    }
  }

  private func sendHeartbeat() async {
    guard let service = geminiService else { return }
    do {
      try await service.sendClientTextTurn(Self.heartbeatMarker)
      appendHeartbeatActivity()
    } catch {
      // Transient send errors are non-fatal — the next scheduled tick will retry.
      print("[Coaching] heartbeat send failed: \(error)")
    }
  }

  private func appendHeartbeatActivity() {
    activity.append(ActivityEntry(
      kind: .toolCall(name: "heartbeat"),
      text: "[check]",
      timestamp: Date()
    ))
    trimActivity()
  }

  private func applyLearnerToolResult(name: String, args: [String: Any], result: [String: Any]) {
    switch name {
    case "advance_step":
      if let status = result["status"] as? String, status == "completed" {
        if let start = sessionStartTime {
          frozenSessionDuration = Date().timeIntervalSince(start)
        }
        isCompleted = true
        currentStepIndex = max(0, procedure.steps.count - 1)
        if let rid = sessionRecordId {
          progressStore?.updateSession(
            id: rid,
            stepsCompleted: procedure.steps.count,
            status: .completed
          )
        }
      } else if let newStep = result["new_step"] as? Int {
        isCompleted = false
        currentStepIndex = max(0, newStep - 1)
        if let rid = sessionRecordId {
          progressStore?.updateSession(
            id: rid,
            stepsCompleted: currentStepIndex,
            status: .inProgress
          )
        }
      }

    case "get_reference_clip":
      showPiP = true

    case "go_to_step":
      if let stepNumber = result["current_step"] as? Int {
        isCompleted = false
        currentStepIndex = max(0, stepNumber - 1)
        if let rid = sessionRecordId {
          progressStore?.updateSession(
            id: rid,
            stepsCompleted: currentStepIndex,
            status: .inProgress
          )
        }
      }

    default:
      break
    }
  }

  private func syncGeminiAfterManualNavigation(
    direction: StepNavigationDirection,
    result: [String: Any]
  ) async {
    guard let geminiService else {
      print("[Coaching] Manual step sync skipped: Gemini service unavailable")
      return
    }

    let syncText = manualNavigationSyncText(direction: direction, result: result)

    do {
      try await geminiService.sendClientTextTurn(syncText)
    } catch {
      print("[Coaching] Manual step sync message failed: \(error.localizedDescription)")
    }
  }

  private func manualNavigationSyncText(
    direction: StepNavigationDirection,
    result: [String: Any]
  ) -> String {
    if let stepNumber = (result["current_step"] as? Int) ?? (result["new_step"] as? Int),
       let title = result["step_title"] as? String {
      return "I manually moved to step \(stepNumber), \(title). Continue coaching from the current step."
    }

    switch direction {
    case .next:
      return "I manually moved to the next step. Continue coaching from the current step."
    case .previous:
      return "I manually went back one step. Continue coaching from the current step."
    }
  }
}
