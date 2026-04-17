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
  private let transport: CaptureTransport
  private var deviceSession: DeviceSession?
  private var streamSession: StreamSession?
  private var iPhoneCamera: IPhoneCameraCapture?
  private var iPhoneVideoSource: IPhoneCoachingCameraSource?
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

  /// Serializes camera setup / teardown so `endSession → stopCameraStream`
  /// can't race a concurrent `setupCameraStream` (reconnect, rapid dismiss+reopen).
  /// Each call appends to this chain and awaits the prior lifecycle step.
  private var cameraLifecycleTask: Task<Void, Never>?

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
  // Set of in-flight Gemini tool-call ids. Gate is closed while non-empty.
  // Using a Set (not a single Optional<String>) so that if Gemini ever emits
  // multiple functionCalls in one toolCall frame — which the Live API spec
  // allows — the first to finish doesn't prematurely reopen the audio/video
  // send gate while the second is still being dispatched to the server.
  private var pendingToolCallIds: Set<String> = []
  private var isGeminiReady = false  // gates audio send hot path; mirrors .connected state
  private var cancellables: Set<AnyCancellable> = []
  private weak var progressStore: LocalProgressStore?

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

  init(
    procedure: ProcedureResponse,
    wearables: WearablesInterface,
    serverBaseURL: String,
    transport: CaptureTransport = .glasses
  ) {
    self.procedure = procedure
    self.wearables = wearables
    self.serverBaseURL = serverBaseURL
    self.transport = transport
  }

  func startSession(progressStore: LocalProgressStore) {
    print("[Coaching] ── session STARTED (transport=\(transport), procedure=\(procedure.id))")
    // Defensive reset of everything that could leak from a prior session.
    // Today the VM is re-created on each fullScreenCover present, so these
    // are normally already defaults — but this guards against SwiftUI caching
    // or any in-flight closures from a prior run racing the new setup.
    currentStepIndex = 0
    isCompleted = false
    frozenSessionDuration = nil
    isMuted = false
    showPiP = false
    voiceStatus = "Connecting..."
    isAISpeaking = false
    geminiConnectionState = .disconnected
    activity = []
    isSendingAudio = true
    isGeminiReady = false
    audioGateWasOpen = false
    pendingToolCallIds.removeAll()
    lastVideoSendAt = nil
    isForwardingFrame = false
    learnerTurnOpen = false
    assistantTurnOpen = false
    resumptionHandle = nil
    isResuming = false
    cancellables.removeAll()

    self.progressStore = progressStore
    sessionStartTime = Date()
    let record = progressStore.startSession(
      procedureId: procedure.id,
      procedureTitle: procedure.title,
      totalSteps: procedure.steps.count
    )
    sessionRecordId = record.id

    // Start camera stream for the chosen transport.
    switch transport {
    case .glasses:
      setupCameraStream()
    case .iPhone:
      setupIPhoneCameraStream()
    }

    // Start Gemini Live audio session
    Task {
      await startGeminiLiveSession()
    }
  }

  func endSession(progressStore: LocalProgressStore) {
    guard let recordId = sessionRecordId else { return }
    let status: SessionStatus = isCompleted ? .completed : .abandoned
    progressStore.updateSession(id: recordId, stepsCompleted: currentStepIndex, status: status)

    // Snapshot before stopGeminiLiveSession() nils them out, then fire the
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
    // 1. Set up audio manager — pin to built-in mic + loudspeaker when the
    // learner picked the iPhone transport, otherwise allow HFP glasses route.
    let audioMode: AudioSessionMode = (transport == .iPhone) ? .coachingPhoneOnly : .coaching
    let audio = AudioSessionManager(mode: audioMode)
    self.audioManager = audio

    let micGranted = await audio.requestMicrophonePermission()
    guard micGranted else {
      voiceStatus = "Mic denied"
      print("[Coaching] Microphone permission denied")
      return
    }

    // 2. Start learner session on server to get ephemeral token.
    // Read the user's auto-advance preference from the same UserDefaults key
    // that ProfileView's @AppStorage("autoAdvanceEnabled") writes. Using
    // `object(forKey:) as? Bool ?? true` preserves the @AppStorage default
    // (true) when the key has never been written — otherwise
    // UserDefaults.bool(forKey:) returns false for missing keys and we'd
    // disagree with the UI on first launch.
    let autoAdvance = UserDefaults.standard.object(forKey: "autoAdvanceEnabled") as? Bool ?? true
    print("[Coaching] auto_advance = \(autoAdvance) (from UserDefaults)")

    // Voice comes from @AppStorage("geminiVoice") written by
    // VoiceSelectionView / ProfileView. Reading UserDefaults directly keeps
    // the VM signature stable and mirrors how autoAdvance is consumed above.
    let selectedVoice = UserDefaults.standard.string(forKey: "geminiVoice") ?? "Puck"
    print("[Coaching] voice = \(selectedVoice) (from UserDefaults)")

    voiceStatus = "Starting session..."
    let apiService = ProcedureAPIService()
    let sessionResponse: LearnerSessionStartResponse
    do {
      sessionResponse = try await apiService.startLearnerSession(
        procedureId: procedure.id,
        voice: selectedVoice,
        autoAdvance: autoAdvance
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
      let noTool = self.pendingToolCallIds.isEmpty
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

    // Mirror the audio manager's isAISpeaking onto the VM. Combine sink
    // instead of a 200ms poll — previously the poll could race with
    // onTurnComplete and cause UI flicker (true→false→true→false as the
    // playback queue finished draining).
    observeAudioIsAISpeaking(audio)
  }

  private func observeGeminiConnectionState(_ gemini: GeminiLiveService) {
    gemini.$connectionState
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        guard let self = self else { return }
        // Log every transition (was only "connected" before) so we can see
        // when the VM gets stuck in .connecting / .error states.
        print("[Coaching] Gemini connection state → \(state)")
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
      // No resumption handle yet (pre-first-update). Mint a fresh token
      // before retry — the cached token from session/start was likely
      // consumed by the failed handshake, and Google's uses=1 semantics
      // reject reusing it. Without this pre-mint, gemini.retry() would
      // burn a handshake on the spent token and only then auto-refresh.
      print("[Coaching] Reconnect (\(reason)): no handle yet, refreshing token + retrying")
      do {
        _ = try await tm.forceRefresh()
      } catch {
        print("[Coaching] Plain-retry token refresh failed: \(error)")
        voiceStatus = "Connection error"
        return
      }
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
    // Order matters here for graceful shutdown:
    //   1. Close the audio send gate so the mic-tap closure stops queueing
    //      sends into a WebSocket that's about to close (`try? await` would
    //      otherwise silently eat a torrent of "notConnected" errors).
    //   2. Drop Combine subscriptions so no state handler re-enters mid-teardown.
    //   3. Stop audio capture BEFORE disconnecting Gemini — guarantees no more
    //      mic buffers can race the WebSocket close.
    //   4. Disconnect Gemini, then nil out the service so tool-call callbacks
    //      can't reach a dead socket.
    //   5. Wipe per-session state so a subsequent `startSession()` starts clean.
    isSendingAudio = false
    isGeminiReady = false
    audioGateWasOpen = false
    cancellables.removeAll()

    audioManager?.stopCapture()
    geminiService?.disconnect()

    geminiService = nil
    audioManager = nil
    tokenManager = nil
    sessionId = nil
    pendingToolCallIds.removeAll()
    lastVideoSendAt = nil
    isForwardingFrame = false
    learnerTurnOpen = false
    assistantTurnOpen = false
    resumptionHandle = nil
    isResuming = false
    voiceStatus = "Ended"
    geminiConnectionState = .disconnected
  }

  private func observeAudioIsAISpeaking(_ audio: AudioSessionManager) {
    audio.$isAISpeaking
      .receive(on: DispatchQueue.main)
      .sink { [weak self] speaking in
        guard let self = self else { return }
        self.isAISpeaking = speaking
        if speaking, !self.isMuted {
          self.voiceStatus = "AI speaking"
        }
      }
      .store(in: &cancellables)
  }

  // MARK: - Tool Call Handling

  private func handleToolCall(id: String, name: String, args: [String: Any]) async {
    guard let sessionId = sessionId else { return }

    // Close the send gate for the lifetime of THIS tool call. Using a Set
    // keeps the gate closed until every in-flight tool call completes.
    pendingToolCallIds.insert(id)

    // Clear playback buffer — Gemini stops speaking during tool calls
    audioManager?.clearPlaybackBuffer(reason: "tool-call")

    let startedAt = Date()
    print("[Coaching] ▶ Tool call START name=\(name) id=\(id) args=\(args)")

    // Forward to server
    let result = await forwardToolCallToServer(
      sessionId: sessionId,
      toolCallId: id,
      functionName: name,
      args: args
    )
    let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
    print("[Coaching] ◀ Tool call DONE  name=\(name) id=\(id) result=\(result) (\(elapsedMs)ms)")

    // Update local state based on tool call. Server returns step numbers as
    // flat Ints: `new_step` for advance_step, `current_step` for go_to_step.
    switch name {
    case "advance_step":
      if let status = result["status"] as? String, status == "completed" {
        if let start = sessionStartTime {
          frozenSessionDuration = Date().timeIntervalSince(start)
        }
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
      print("[Coaching] ✓ Tool response ACK sent to Gemini name=\(name) id=\(id)")
    } catch {
      print("[Coaching] ✗ Failed to send tool response name=\(name) id=\(id): \(error)")
    }

    // Drop this call's id. Gate reopens only when the set is empty, so a
    // concurrent tool call still in flight keeps the gate closed.
    pendingToolCallIds.remove(id)
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

    // Server contract: ToolCallRequest { tool_name: str, arguments: dict }.
    // The function-call `id` is round-tripped back to Gemini via
    // sendToolResponse — the server doesn't need it.
    let body: [String: Any] = [
      "tool_name": functionName,
      "arguments": args,
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let http = response as? HTTPURLResponse else {
        print("[Coaching] Tool call: non-HTTP response")
        return [
          "error": "transient_network_failure",
          "message": "No HTTP response from server",
          "retryable": true,
        ]
      }

      guard (200...299).contains(http.statusCode) else {
        let bodySnippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
        print("[Coaching] Tool call failed: HTTP \(http.statusCode) body=\(bodySnippet)")
        return [
          "error": "server_rejected_tool_call",
          "message": "HTTP \(http.statusCode): \(bodySnippet)",
          "retryable": http.statusCode >= 500,  // 4xx is a contract bug — not retryable
        ]
      }

      // Server wraps the handler result as {"result": {...}} (ToolCallResponse).
      // Unwrap so Gemini sees the raw result fields (status, new_step, etc.).
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let inner = json["result"] as? [String: Any] {
          return inner
        }
        return json
      }
      return ["status": "ok"]
    } catch {
      print("[Coaching] Tool call forward error: \(error)")
      return [
        "error": "transient_network_failure",
        "message": error.localizedDescription,
        "retryable": true,
      ]
    }
  }

  // MARK: - Camera Stream

  private func setupCameraStream() {
    let prior = cameraLifecycleTask
    cameraLifecycleTask = Task { [weak self] in
      await prior?.value                     // wait for any in-flight stop/start
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
      if let existing = self.deviceSession {
        existing.stop()
        self.deviceSession = nil
      }

      // 0.6 API: wearables.createSession → deviceSession.addStream.
      // StreamSession has no public init anymore; it's a Capability attached
      // to a DeviceSession.
      let deviceSelector = AutoDeviceSelector(wearables: self.wearables)
      let config = StreamSessionConfig(
        videoCodec: .raw,
        resolution: .low,
        frameRate: 24
      )
      let session: DeviceSession
      let stream: StreamSession
      do {
        session = try self.wearables.createSession(deviceSelector: deviceSelector)
        guard let s = try session.addStream(config: config) else {
          print("[Coaching] Could not attach stream capability to the device session")
          return
        }
        stream = s
      } catch {
        print("[Coaching] Failed to create coaching stream session: \(error)")
        return
      }
      self.deviceSession = session
      self.streamSession = stream

      self.videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] videoFrame in
        Task { @MainActor [weak self] in
          self?.forwardFrameToGemini(videoFrame)
        }
      }

      do {
        try session.start()
      } catch {
        print("[Coaching] Failed to start device session: \(error)")
        return
      }
      await stream.start()
    }
  }

  /// Enqueue camera teardown onto the lifecycle chain. Safe to call while a
  /// prior setup Task is still running — this one awaits it first, so start
  /// and stop never race for the same `streamSession` / `iPhoneCamera` refs.
  private func stopCameraStream() {
    let prior = cameraLifecycleTask
    cameraLifecycleTask = Task { [weak self] in
      await prior?.value
      guard let self = self else { return }

      // Listener tokens first — so trailing frame/state events can't push into
      // a half-dead VM during the async stop below.
      self.videoFrameListenerToken = nil
      self.stateListenerToken = nil

      if let session = self.streamSession {
        await session.stop()
      }
      self.deviceSession?.stop()
      self.streamSession = nil
      self.deviceSession = nil

      // iPhone transport — drop the sample-buffer handler FIRST so a trailing
      // AVCaptureSession frame can't reach a dying JPEG throttler.
      self.iPhoneCamera?.onSampleBuffer = nil
      self.iPhoneCamera?.stop()
      self.iPhoneCamera = nil
      self.iPhoneVideoSource = nil
    }
  }

  /// iPhone-native video source for coaching. Mirrors `forwardFrameToGemini`
  /// but drives JPEGs out of `AVCaptureSession` via `IPhoneCoachingCameraSource`
  /// (same 0.5 fps / 0.5 quality throttle as the glasses path).
  private func setupIPhoneCameraStream() {
    let prior = cameraLifecycleTask
    cameraLifecycleTask = Task { [weak self] in
      await prior?.value                     // wait for any in-flight stop/start
      guard let self = self else { return }

      // Defensive: drop a prior iPhone session if we raced (re-enter from onAppear).
      self.iPhoneCamera?.onSampleBuffer = nil
      self.iPhoneCamera?.stop()
      self.iPhoneCamera = nil
      self.iPhoneVideoSource = nil

      let camera = IPhoneCameraCapture()
      let granted = await camera.requestPermission()
      guard granted else {
        self.voiceStatus = "Camera denied"
        print("[Coaching] iPhone camera permission denied")
        return
      }

      let source = IPhoneCoachingCameraSource(
        minInterval: self.videoMinInterval,
        jpegQuality: self.videoJpegQuality
      ) { [weak self] jpeg in
        // Gate in the same way `forwardFrameToGemini` does for the glasses path.
        let gate = await MainActor.run { [weak self] () -> Bool in
          guard let self = self else { return false }
          return self.isGeminiReady && self.pendingToolCallIds.isEmpty
        }
        guard gate else { return }
        try? await self?.geminiService?.sendVideoFrame(jpeg)
      }
      self.iPhoneVideoSource = source

      camera.onSampleBuffer = { [weak source] sampleBuffer in
        source?.submit(sampleBuffer)
      }

      do {
        try await camera.start()
      } catch {
        print("[Coaching] iPhone camera failed to start: \(error)")
        return
      }
      self.iPhoneCamera = camera
    }
  }

  // MARK: - Frame forwarding

  private func forwardFrameToGemini(_ frame: VideoFrame) {
    guard isGeminiReady, pendingToolCallIds.isEmpty, !isForwardingFrame else { return }
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
