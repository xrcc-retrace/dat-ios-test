import Combine
import MWDATCamera
import MWDATCore
import SwiftUI

struct ActivityEntry: Identifiable, Equatable {
  enum Kind: Equatable {
    case toolCall(name: String)
    case learner
    case assistant
  }

  let id = UUID()
  let kind: Kind
  var text: String
  let timestamp: Date
}

@MainActor
class CoachingSessionViewModel: ObservableObject {
  @Published var currentStepIndex = 0
  @Published var isCompleted = false
  @Published var isMuted = false
  @Published var showPiP = false
  @Published var voiceStatus = "Connecting..."
  @Published var isAISpeaking = false
  @Published var geminiConnectionState: GeminiLiveService.ConnectionState = .disconnected
  @Published var activity: [ActivityEntry] = []

  private let procedure: ProcedureResponse
  private let wearables: WearablesInterface
  private let serverBaseURL: String
  private var streamSession: StreamSession?
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var sessionStartTime: Date?
  private var sessionRecordId: String?

  // Video forwarding to Gemini Live (≈0.5 fps JPEG — keeps token burn to
  // ~33 tok/s at LOW media resolution so 128k fills in ~25 min before
  // compression has to kick in).
  private var lastVideoSendAt: Date?
  private let videoMinInterval: TimeInterval = 2.0
  private let videoJpegQuality: CGFloat = 0.5
  private var isForwardingFrame = false

  // Session resumption — populated from sessionResumptionUpdate.newHandle.
  private var resumptionHandle: String?
  private var isResuming = false

  // Audio send gate state — for edge-triggered logging (only log OPEN/CLOSED transitions).
  private var audioGateWasOpen = false

  // Transcript coalescing — next delta of matching kind appends to last entry
  // unless the previous turn closed (turnComplete or speaker change).
  private var learnerTurnOpen = false
  private var assistantTurnOpen = false
  private let activityMaxEntries = 200

  // Audio + Gemini Live
  private var audioManager: AudioSessionManager?
  private var geminiService: GeminiLiveService?
  private var tokenManager: GeminiTokenManager?
  private var sessionId: String?
  private var isSendingAudio = true
  private var pendingToolCallId: String?  // non-nil while waiting for server tool response
  private var isGeminiReady = false  // gates audio send hot path; mirrors .connected state
  private var cancellables: Set<AnyCancellable> = []
  private weak var progressStore: LocalProgressStore?

  var currentStep: ProcedureStepResponse? {
    guard currentStepIndex < procedure.steps.count else { return nil }
    return procedure.steps.sorted { $0.stepNumber < $1.stepNumber }[currentStepIndex]
  }

  var formattedSessionDuration: String {
    guard let start = sessionStartTime else { return "0:00" }
    let elapsed = Date().timeIntervalSince(start)
    let mins = Int(elapsed) / 60
    let secs = Int(elapsed) % 60
    return String(format: "%d:%02d", mins, secs)
  }

  init(procedure: ProcedureResponse, wearables: WearablesInterface, serverBaseURL: String) {
    self.procedure = procedure
    self.wearables = wearables
    self.serverBaseURL = serverBaseURL
  }

  func startSession(progressStore: LocalProgressStore) {
    self.progressStore = progressStore
    sessionStartTime = Date()
    let record = progressStore.startSession(
      procedureId: procedure.id,
      procedureTitle: procedure.title,
      totalSteps: procedure.steps.count
    )
    sessionRecordId = record.id

    // Start glasses camera stream
    setupCameraStream()

    // Start Gemini Live audio session
    Task {
      await startGeminiLiveSession()
    }
  }

  func endSession(progressStore: LocalProgressStore) {
    guard let recordId = sessionRecordId else { return }
    let status: SessionStatus = isCompleted ? .completed : .abandoned
    progressStore.updateSession(id: recordId, stepsCompleted: currentStepIndex, status: status)
    stopGeminiLiveSession()
    Task { await stopCameraStream() }
  }

  func retryGemini() {
    Task { await reconnectWithResumption(reason: "user retry") }
  }

  func toggleMute() {
    isMuted.toggle()
    isSendingAudio = !isMuted
    if isMuted {
      voiceStatus = "Muted"
    } else if geminiConnectionState == .connected {
      voiceStatus = "Listening"
    }
  }

  // MARK: - Gemini Live Session

  private func startGeminiLiveSession() async {
    // 1. Set up audio manager
    let audio = AudioSessionManager()
    self.audioManager = audio

    let micGranted = await audio.requestMicrophonePermission()
    guard micGranted else {
      voiceStatus = "Mic denied"
      print("[Coaching] Microphone permission denied")
      return
    }

    // 2. Start learner session on server to get ephemeral token
    voiceStatus = "Starting session..."
    let apiService = ProcedureAPIService()
    let sessionResponse: LearnerSessionStartResponse
    do {
      sessionResponse = try await apiService.startLearnerSession(
        procedureId: procedure.id,
        voice: "Puck"  // Default voice
      )
    } catch {
      voiceStatus = "Session error"
      print("[Coaching] Failed to start learner session: \(error)")
      return
    }

    self.sessionId = sessionResponse.sessionId

    // 3. Set up token manager
    let tm = GeminiTokenManager(
      sessionId: sessionResponse.sessionId,
      serverBaseURL: serverBaseURL
    )
    await tm.setInitialToken(sessionResponse.ephemeralToken)
    self.tokenManager = tm

    // 4. Create Gemini Live service and wire callbacks
    let gemini = GeminiLiveService(tokenManager: tm)
    self.geminiService = gemini

    gemini.onAudioData = { [weak self] data in
      self?.audioManager?.playPcm16Audio(data)
    }

    gemini.onTurnComplete = { [weak self] in
      Task { @MainActor in
        self?.isAISpeaking = false
        self?.assistantTurnOpen = false
        self?.learnerTurnOpen = false
        if !(self?.isMuted ?? true) {
          self?.voiceStatus = "Listening"
        }
      }
    }

    gemini.onToolCall = { [weak self] id, name, args in
      Task { @MainActor in
        await self?.handleToolCall(id: id, name: name, args: args)
      }
    }

    gemini.onInputTranscript = { [weak self] text in
      Task { @MainActor in
        self?.appendTranscript(kind: .learner, delta: text)
      }
    }

    gemini.onOutputTranscript = { [weak self] text in
      Task { @MainActor in
        self?.appendTranscript(kind: .assistant, delta: text)
      }
    }

    gemini.onResumptionUpdate = { [weak self] handle in
      Task { @MainActor in
        self?.resumptionHandle = handle
      }
    }

    gemini.onGoAway = { [weak self] timeLeft in
      Task { @MainActor in
        await self?.reconnectWithResumption(reason: "goAway (timeLeft=\(timeLeft)s)")
      }
    }

    gemini.onInterrupted = { [weak self] in
      Task { @MainActor in
        print("[Coaching] Barge-in → clearing playback buffer")
        self?.audioManager?.clearPlaybackBuffer(reason: "barge-in")
      }
    }

    // Observe connection state transitions (not a one-shot snapshot).
    observeGeminiConnectionState(gemini)

    // Observe audio manager's isAISpeaking
    audio.onAudioBuffer = { [weak self] buffer, _ in
      guard let self = self else { return }
      let sendingOk = self.isSendingAudio
      let noTool = self.pendingToolCallId == nil
      let ready = self.isGeminiReady
      let gateOpen = sendingOk && noTool && ready

      // Edge-triggered log — only print when the gate state flips, so we
      // can see "why audio stopped" without spamming every buffer.
      if gateOpen != self.audioGateWasOpen {
        self.audioGateWasOpen = gateOpen
        if gateOpen {
          print("[Coaching] Audio send gate OPEN — mic → Gemini live")
        } else {
          let reason: String
          if !ready { reason = "Gemini not ready" }
          else if !noTool { reason = "pending tool call" }
          else { reason = "muted" }
          print("[Coaching] Audio send gate CLOSED — \(reason)")
        }
      }

      guard gateOpen else { return }
      guard let pcmData = self.audioManager?.convertBufferForSend(buffer) else { return }

      Task {
        try? await self.geminiService?.sendAudio(pcmData)
      }
    }

    // 5. Connect to Gemini Live (handshake confirmation arrives via the state sink)
    voiceStatus = "Connecting..."
    await gemini.connect()

    // 6. Start audio capture (this also starts playback)
    audio.startCapture()

    // Observe isAISpeaking polling loop
    observeGeminiState()
  }

  private func observeGeminiConnectionState(_ gemini: GeminiLiveService) {
    gemini.$connectionState
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        guard let self = self else { return }
        self.geminiConnectionState = state
        switch state {
        case .connected:
          self.isGeminiReady = true
          self.voiceStatus = self.isMuted ? "Muted" : "Listening"
          print("[Coaching] Gemini Live connected")
        case .connecting:
          self.isGeminiReady = false
          self.voiceStatus = "Connecting..."
        case .error(let msg):
          self.isGeminiReady = false
          self.voiceStatus = "Connection error"
          print("[Coaching] Gemini Live error: \(msg)")
          // Hard drop after bounded retries exhausted. If we have a resumption
          // handle, try to reopen the session with it before surfacing the
          // failure to the user.
          if self.resumptionHandle != nil, !self.isResuming {
            Task { @MainActor [weak self] in
              await self?.reconnectWithResumption(reason: "state=error")
            }
          }
        case .disconnected:
          self.isGeminiReady = false
        }
      }
      .store(in: &cancellables)
  }

  /// Bring the Gemini Live WebSocket back up using the most recent resumption
  /// handle, then inject a context summary so the model re-orients.
  /// Falls back to a plain retry when no handle is available yet.
  private func reconnectWithResumption(reason: String) async {
    guard !isResuming else {
      print("[Coaching] Reconnect requested (\(reason)) but already resuming")
      return
    }
    guard let tm = tokenManager, let gemini = geminiService, let sid = sessionId else {
      return
    }
    guard let handle = resumptionHandle else {
      print("[Coaching] Reconnect (\(reason)): no handle yet, plain retry")
      await gemini.retry()
      return
    }

    isResuming = true
    voiceStatus = "Reconnecting…"
    print("[Coaching] Reconnecting with resumption handle (\(reason))")

    do {
      // Ask the server to mint a new token carrying `handle` — it bakes it
      // into SessionResumptionConfig(handle=…) so the next WS continues the
      // prior session with compressed context intact.
      _ = try await tm.forceRefresh(handle: handle)
    } catch {
      print("[Coaching] Resumption token mint failed: \(error)")
      voiceStatus = "Connection error"
      isResuming = false
      return
    }

    // retry() resets the bounded retry counter and re-performs the full
    // connect sequence; validToken() returns the handle-baked token we just
    // cached above.
    await gemini.retry()

    // Wait for didOpenWithProtocol to flip state to .connected before we try
    // to send the context summary. Upper bound keeps us from hanging forever
    // if the new socket also fails.
    let deadline = Date().addingTimeInterval(5.0)
    while gemini.connectionState != .connected, Date() < deadline {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }

    guard gemini.connectionState == .connected else {
      print("[Coaching] Resumed socket did not open in 5s; aborting summary inject")
      isResuming = false
      return
    }

    do {
      let summary = try await ProcedureAPIService().fetchContextSummary(sessionId: sid)
      try await gemini.sendClientTextTurn(
        "Session resumed after a brief interruption. Current coaching context:\n\(summary)"
      )
      print("[Coaching] Resumed — injected context summary")
    } catch {
      print("[Coaching] Failed to inject context summary: \(error)")
    }

    isResuming = false
  }

  private func stopGeminiLiveSession() {
    cancellables.removeAll()
    geminiService?.disconnect()
    audioManager?.stopCapture()
    geminiService = nil
    audioManager = nil
    tokenManager = nil
    sessionId = nil
    pendingToolCallId = nil
    isGeminiReady = false
    lastVideoSendAt = nil
    isForwardingFrame = false
    learnerTurnOpen = false
    assistantTurnOpen = false
    resumptionHandle = nil
    isResuming = false
    audioGateWasOpen = false
    voiceStatus = "Ended"
    geminiConnectionState = .disconnected
  }

  private func observeGeminiState() {
    // Periodically sync isAISpeaking from audioManager
    Task { @MainActor in
      while geminiService != nil {
        if let audio = audioManager {
          isAISpeaking = audio.isAISpeaking
          if audio.isAISpeaking && !isMuted {
            voiceStatus = "AI speaking"
          }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
      }
    }
  }

  // MARK: - Tool Call Handling

  private func handleToolCall(id: String, name: String, args: [String: Any]) async {
    guard let sessionId = sessionId else { return }

    // Pause audio sending while tool call is pending
    pendingToolCallId = id

    // Clear playback buffer — Gemini stops speaking during tool calls
    audioManager?.clearPlaybackBuffer(reason: "tool-call")

    print("[Coaching] Tool call: \(name) (id: \(id), args: \(args))")

    // Forward to server
    let result = await forwardToolCallToServer(
      sessionId: sessionId,
      toolCallId: id,
      functionName: name,
      args: args
    )

    // Update local state based on tool call. Server returns step numbers as
    // flat Ints: `new_step` for advance_step, `current_step` for go_to_step.
    switch name {
    case "advance_step":
      if let status = result["status"] as? String, status == "completed" {
        isCompleted = true
        currentStepIndex = procedure.steps.count - 1
        if let rid = sessionRecordId {
          progressStore?.updateSession(
            id: rid, stepsCompleted: procedure.steps.count, status: .completed)
        }
      } else if let newStep = result["new_step"] as? Int {
        currentStepIndex = newStep - 1
        if let rid = sessionRecordId {
          progressStore?.updateSession(
            id: rid, stepsCompleted: currentStepIndex, status: .inProgress)
        }
      }

    case "get_reference_clip":
      showPiP = true

    case "go_to_step":
      if let stepNumber = result["current_step"] as? Int {
        currentStepIndex = stepNumber - 1
        if let rid = sessionRecordId {
          progressStore?.updateSession(
            id: rid, stepsCompleted: currentStepIndex, status: .inProgress)
        }
      }

    default:
      break
    }

    appendToolCall(name: name, args: args, result: result)

    // Send tool response back to Gemini
    do {
      try await geminiService?.sendToolResponse(
        id: id,
        name: name,
        response: result
      )
    } catch {
      print("[Coaching] Failed to send tool response: \(error)")
    }

    // Resume audio sending
    pendingToolCallId = nil
  }

  private func forwardToolCallToServer(
    sessionId: String,
    toolCallId: String,
    functionName: String,
    args: [String: Any]
  ) async -> [String: Any] {
    guard let url = URL(string: "\(serverBaseURL)/api/learner/session/\(sessionId)/tool-call")
    else {
      return ["error": "Invalid URL"]
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 10

    let body: [String: Any] = [
      "tool_call_id": toolCallId,
      "function_name": functionName,
      "arguments": args,
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        return ["error": "Server error (HTTP \(statusCode))"]
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return json
      }
      return ["status": "ok"]
    } catch {
      print("[Coaching] Tool call forward error: \(error)")
      return ["error": error.localizedDescription]
    }
  }

  // MARK: - Camera Stream

  private func setupCameraStream() {
    Task { [weak self] in
      guard let self = self else { return }

      // Defensive: fully stop any prior session (e.g., from a repeat onAppear)
      // before bringing up a new one. The DAT SDK returns WARPStreamClient
      // error 3 when a new session races with an unstopped previous one.
      if let existing = self.streamSession {
        await existing.stop()
        self.streamSession = nil
        self.videoFrameListenerToken = nil
        self.stateListenerToken = nil
      }

      let deviceSelector = AutoDeviceSelector(wearables: self.wearables)
      let config = StreamSessionConfig(
        videoCodec: .raw,
        resolution: .low,
        frameRate: 24
      )
      let session = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)
      self.streamSession = session

      self.videoFrameListenerToken = session.videoFramePublisher.listen { [weak self] videoFrame in
        Task { @MainActor [weak self] in
          self?.forwardFrameToGemini(videoFrame)
        }
      }

      await session.start()
    }
  }

  private func stopCameraStream() async {
    if let session = streamSession {
      await session.stop()
    }
    streamSession = nil
    stateListenerToken = nil
    videoFrameListenerToken = nil
  }

  // MARK: - Frame forwarding

  private func forwardFrameToGemini(_ frame: VideoFrame) {
    guard isGeminiReady, pendingToolCallId == nil, !isForwardingFrame else { return }
    let now = Date()
    if let last = lastVideoSendAt, now.timeIntervalSince(last) < videoMinInterval {
      return
    }
    guard let image = frame.makeUIImage(),
          let jpeg = image.jpegData(compressionQuality: videoJpegQuality)
    else { return }

    lastVideoSendAt = now
    isForwardingFrame = true
    Task { [weak self] in
      defer { Task { @MainActor in self?.isForwardingFrame = false } }
      try? await self?.geminiService?.sendVideoFrame(jpeg)
    }
  }

  // MARK: - Activity feed

  private func appendTranscript(kind: ActivityEntry.Kind, delta: String) {
    let turnOpen: Bool
    switch kind {
    case .learner: turnOpen = learnerTurnOpen
    case .assistant: turnOpen = assistantTurnOpen
    case .toolCall: return
    }

    if turnOpen,
       let last = activity.last,
       last.kind == kind {
      var updated = last
      updated.text += delta
      activity[activity.count - 1] = updated
    } else {
      activity.append(ActivityEntry(kind: kind, text: delta, timestamp: Date()))
      switch kind {
      case .learner:
        learnerTurnOpen = true
        assistantTurnOpen = false
      case .assistant:
        assistantTurnOpen = true
        learnerTurnOpen = false
      case .toolCall:
        break
      }
      trimActivity()
    }
  }

  private func appendToolCall(name: String, args: [String: Any], result: [String: Any]) {
    let summary = toolCallSummary(name: name, args: args, result: result)
    activity.append(ActivityEntry(
      kind: .toolCall(name: name),
      text: summary,
      timestamp: Date()
    ))
    // A tool call closes both turns so the next transcript starts fresh.
    learnerTurnOpen = false
    assistantTurnOpen = false
    trimActivity()
  }

  private func toolCallSummary(name: String, args: [String: Any], result: [String: Any]) -> String {
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

  private func trimActivity() {
    if activity.count > activityMaxEntries {
      activity.removeFirst(activity.count - activityMaxEntries)
    }
  }
}
