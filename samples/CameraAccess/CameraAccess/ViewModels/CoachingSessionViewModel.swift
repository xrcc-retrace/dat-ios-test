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

/// Direction the step card slides during a step transition. Drives the
/// asymmetric `.transition(...)` on the lens step card. Forward = old
/// slides off-left, new arrives from the right; backward = inverse.
enum SlideDirection: Equatable {
  case none
  case forward
  case backward
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
  @Published private(set) var stepJustCompletedTick: Int = 0

  /// Step index whose card the lens HUD should render. Lags
  /// `currentStepIndex` by 0.7s during a forward `advance_step`
  /// celebration so the OLD card stays on screen long enough to play
  /// the green-overlay + checkmark sequence before sliding off. For
  /// every other path (initial seed, `go_to_step`, completion-page
  /// swap) it tracks `currentStepIndex` synchronously.
  @Published private(set) var displayedStepIndex: Int = 0
  /// When non-nil, the card matching this index renders the
  /// celebration overlay (green fill → checkmark → "Step completed").
  /// Only set during forward `advance_step`. The OLD index goes here
  /// — the overlay rides the OLD card off-screen during the slide.
  @Published private(set) var celebratingStepIndex: Int? = nil
  /// Drives the asymmetric `.transition(...)` on the lens step card.
  /// `.none` while idle so SwiftUI doesn't apply a transition to the
  /// initial render.
  @Published private(set) var slideDirection: SlideDirection = .none

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
  /// Quiet-streak window used by the heartbeat gate. The gate refuses to
  /// send if `lastAudioActivityAt` is within this window. 1.5s comfortably
  /// bridges the longest natural gaps between Gemini's audio chunks
  /// (~0.3-0.5s at sentence boundaries) and the local playback tail, so
  /// the gate cannot pass mid-utterance from either side.
  private static let heartbeatQuietWindow: TimeInterval = 1.5

  // MARK: - Computed

  var currentStep: ProcedureStepResponse? {
    guard currentStepIndex < procedure.steps.count else { return nil }
    return procedure.steps.sorted { $0.stepNumber < $1.stepNumber }[currentStepIndex]
  }

  /// Step the lens HUD should render. Equal to `currentStep` except
  /// during the brief celebration window after a forward `advance_step`,
  /// where it lags so the OLD card stays visible while the green
  /// overlay + checkmark play before the slide.
  var displayedStep: ProcedureStepResponse? {
    let sorted = procedure.steps.sorted { $0.stepNumber < $1.stepNumber }
    guard displayedStepIndex < sorted.count else { return nil }
    return sorted[displayedStepIndex]
  }

  // MARK: - Step transition timeline
  //
  // Forward `advance_step` runs a staged ~1.0s timeline (0.20s green
  // fade-in, 0.20s checkmark arrival, 0.30s hold, 0.30s slide). Other
  // step transitions just slide directionally with no overlay. The VM
  // owns the timeline so durations stay deterministic — view code
  // animates by reacting to published state changes, never by polling.

  private var transitionTask: Task<Void, Never>?

  private func startForwardCelebration(fromIndex: Int, toIndex: Int) {
    transitionTask?.cancel()
    // celebratingStepIndex is the only state that flips at t=0. We
    // intentionally do NOT touch slideDirection or displayedStepIndex
    // here — keeping every other binding stable until the moment of
    // the slide prevents SwiftUI from re-evaluating the host card's
    // `.transition(...)` mid-frame and producing a visible layout
    // twitch before the green overlay fades in.
    celebratingStepIndex = fromIndex
    CompletionFeedback.playStepComplete()  // no-op stub; sound asset deferred
    transitionTask = Task { @MainActor [weak self] in
      // 1.5s = 0.20 fade-in + 0.20 checkmark + 1.10 hold. The longer
      // hold lets the success beat actually register before the slide;
      // the prior 0.30 hold flashed by faster than the user could read
      // "Step completed". Then swap the displayed index so SwiftUI runs
      // the asymmetric slide transition.
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      guard let self, !Task.isCancelled else { return }
      // Set slideDirection and displayedStepIndex in the same
      // transaction so the .transition value is current at the moment
      // .id flips. `withAnimation` opens the spring context that
      // SwiftUI uses for the .id-driven slide.
      self.slideDirection = .forward
      withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
        self.displayedStepIndex = toIndex
      }
      // 0.30s slide window. Keep `celebratingStepIndex == fromIndex`
      // through the whole slide so the OLD card carries its overlay
      // off-screen; clearing it mid-slide would cross-fade the overlay
      // away while the card is still visible.
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }
      self.celebratingStepIndex = nil
      self.slideDirection = .none
    }
  }

  private func slideDisplayedIndex(to targetIndex: Int, direction: SlideDirection) {
    transitionTask?.cancel()
    celebratingStepIndex = nil
    // Set slideDirection and displayedStepIndex in the same
    // transaction so the .transition value is current at the moment
    // .id flips. `withAnimation` opens the spring context that
    // SwiftUI uses for the .id-driven slide.
    slideDirection = direction
    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
      displayedStepIndex = targetIndex
    }
    transitionTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard let self, !Task.isCancelled else { return }
      self.slideDirection = .none
    }
  }

  private func resetTransitionState(toIndex: Int) {
    transitionTask?.cancel()
    transitionTask = nil
    celebratingStepIndex = nil
    slideDirection = .none
    displayedStepIndex = toIndex
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
    resetTransitionState(toIndex: seededIndex)

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
    let selectedVoice = VoiceSettings.storedVoice()
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

  /// Single source of truth for whether the HUD is allowed to mutate the
  /// learner session from a manual swipe. Gates both the swipe affordance and
  /// the commit-time action to prevent races against Gemini readiness and
  /// in-flight tool calls.
  var canPerformManualHUDNavigation: Bool {
    hudStepTransitionState == .idle
      && sessionId != nil
      && isGeminiReady
      && geminiConnectionState == .connected
      && pendingToolCallIds.isEmpty
      && !isCompleted
  }

  func navigateStepFromHUD(direction: StepNavigationDirection) async {
    guard canPerformManualHUDNavigation else { return }
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
      // Foolproof gate: never ship `[check]` while either side is
      // producing audio. See `canSendHeartbeatNow` for the truth table.
      guard self.canSendHeartbeatNow() else {
        // Activity within the quiet window (or the model is mid-turn,
        // or a tool is in flight). Bail this tick and let the fallback
        // re-arm us so a stuck silent stretch doesn't stall forever.
        self.scheduleHeartbeatFallback()
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

  /// Single source of truth for whether a heartbeat is safe to send right
  /// now. Three independent gates — wire-level, local-playback, and
  /// quiet-streak — must all be quiet. Any one alone has a known race;
  /// together they're foolproof.
  ///
  /// - `isModelGenerating`: Gemini wire flag, set on each inbound audio
  ///   chunk and cleared on `turnComplete` / `interrupted` / 2s watchdog.
  ///   Independent of `AVAudioPlayerNode` so it can't be fooled by gaps.
  /// - `isAISpeaking`: belt — local `scheduledBufferCount > 0`.
  /// - quiet streak on `lastAudioActivityAt`: catches inter-chunk gaps,
  ///   the playback tail, and active user speech (mic peak above floor).
  private func canSendHeartbeatNow() -> Bool {
    guard isGeminiReady, pendingToolCallIds.isEmpty else { return false }
    guard !isModelGenerating, !isAISpeaking else { return false }
    let sinceActivity = Date().timeIntervalSince(lastAudioActivityAt)
    return sinceActivity >= Self.heartbeatQuietWindow
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
        let finalIndex = max(0, procedure.steps.count - 1)
        currentStepIndex = finalIndex
        // Procedure-complete swaps the entire page set to
        // `[.completion]` (CoachingCompletionPage takes over). Skip our
        // celebration timeline — that page transition is the finale.
        resetTransitionState(toIndex: finalIndex)
        if let rid = sessionRecordId {
          progressStore?.updateSession(
            id: rid,
            stepsCompleted: procedure.steps.count,
            status: .completed
          )
        }
        stepJustCompletedTick &+= 1
      } else if let newStep = result["new_step"] as? Int {
        let targetIndex = max(0, newStep - 1)
        let oldIndex = currentStepIndex
        let didAdvance = targetIndex != oldIndex
        isCompleted = false
        currentStepIndex = targetIndex
        if let rid = sessionRecordId {
          progressStore?.updateSession(
            id: rid,
            stepsCompleted: currentStepIndex,
            status: .inProgress
          )
        }
        if didAdvance {
          stepJustCompletedTick &+= 1
          if targetIndex > oldIndex {
            startForwardCelebration(fromIndex: oldIndex, toIndex: targetIndex)
          } else {
            // Backward via advance_step is unusual but possible if Gemini
            // emits a lower step number — slide back without overlay.
            slideDisplayedIndex(to: targetIndex, direction: .backward)
          }
        }
      }

    case "get_reference_clip":
      showPiP = true

    case "go_to_step":
      if let stepNumber = result["current_step"] as? Int {
        let targetIndex = max(0, stepNumber - 1)
        let oldIndex = currentStepIndex
        isCompleted = false
        currentStepIndex = targetIndex
        if let rid = sessionRecordId {
          progressStore?.updateSession(
            id: rid,
            stepsCompleted: currentStepIndex,
            status: .inProgress
          )
        }
        if targetIndex != oldIndex {
          // `go_to_step` is a manual jump in either direction. No
          // celebration overlay — only forward `advance_step` marks an
          // actual completion. Slide direction matches travel direction.
          slideDisplayedIndex(
            to: targetIndex,
            direction: targetIndex > oldIndex ? .forward : .backward
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
