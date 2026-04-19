import Combine
import MWDATCamera
import MWDATCore
import SwiftUI

/// Transcript + tool-call entry surfaced in the activity feed.
///
/// Lives here (not in CoachingSessionViewModel) so every mode VM that
/// inherits from `GeminiLiveSessionBase` shares the same type.
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

/// Mode-agnostic base for any Gemini Live session (learner coaching,
/// diagnostic troubleshooting, future on-site worker / Iron Man HUD).
///
/// Absorbs the duplicated machinery that every mode needs:
///   - Audio session setup (mic permission, AEC, gated send)
///   - Camera setup for both transports (.glasses via DAT SDK, .iPhone via AVCaptureSession)
///   - Ephemeral token mint + WebSocket lifecycle + Combine observation
///   - Shared callbacks (audio in, transcripts, barge-in, resumption handle)
///   - Tool-call HTTP ceremony (POST, unwrap, send toolResponse ACK)
///   - Transcript + tool-call coalescing in the activity feed
///   - Teardown order (close gate → drop subs → stop audio → disconnect)
///
/// Subclasses override the `open`/`internal` template hooks below to plug
/// in mode-specific behavior without touching the shared plumbing:
///   - `mintSession()` — what REST endpoint to hit for the initial token
///   - `toolCallURLSuffix` — which `/api/<mode>/session/{id}/tool-call` path
///   - `toolCallTimeoutSeconds` — learner 10s, diagnostic 90s (PDF ingest)
///   - `introSeedText` — first synthetic user turn on initial .connected
///   - `onTurnCompleteExtra()` — coaching schedules heartbeats; others no-op
///   - `handleToolCallExtras(...)` — mode-specific state updates per tool
///   - `audioSessionMode` — `.coaching` on glasses, `.coachingPhoneOnly` elsewhere
///   - `transport` — `.glasses` vs `.iPhone`
///   - `contextSummaryForReconnect()` — coaching fetches from server; others nil
///   - `didEndSession()` — mode cleanup after teardown
@MainActor
class GeminiLiveSessionBase: ObservableObject {

  // MARK: - Published State (observed by views)

  @Published var isMuted = false
  @Published var voiceStatus = "Connecting..."
  @Published var isAISpeaking = false
  @Published var geminiConnectionState: GeminiLiveService.ConnectionState = .disconnected
  @Published var activity: [ActivityEntry] = []

  // MARK: - Inputs

  let wearables: WearablesInterface
  let serverBaseURL: String

  // MARK: - Shared Services (set during startGeminiLiveSession, nilled in teardown)

  var audioManager: AudioSessionManager?
  var geminiService: GeminiLiveService?
  var tokenManager: GeminiTokenManager?
  var sessionId: String?

  // MARK: - Gate state

  var pendingToolCallIds: Set<String> = []
  var isGeminiReady = false
  var isSendingAudio = true
  var audioGateWasOpen = false
  var hasSeededIntro = false

  // MARK: - Transcript coalescing

  var learnerTurnOpen = false
  var assistantTurnOpen = false

  // MARK: - Video forwarding (glasses + iPhone, same throttle)

  var streamSession: StreamSession?
  var deviceSession: DeviceSession?
  var stateListenerToken: AnyListenerToken?
  var videoFrameListenerToken: AnyListenerToken?
  var iPhoneCamera: IPhoneCameraCapture?
  var iPhoneVideoSource: IPhoneCoachingCameraSource?
  var cameraLifecycleTask: Task<Void, Never>?
  var lastVideoSendAt: Date?
  var isForwardingFrame = false

  // MARK: - Resumption (also used by coaching's goAway → reconnect path)

  var resumptionHandle: String?
  var isResuming = false

  // MARK: - Constants

  let activityMaxEntries = 200
  let videoMinInterval: TimeInterval = 2.0
  let videoJpegQuality: CGFloat = 0.5

  // MARK: - Combine

  var cancellables: Set<AnyCancellable> = []

  // MARK: - Init

  init(wearables: WearablesInterface, serverBaseURL: String) {
    self.wearables = wearables
    self.serverBaseURL = serverBaseURL
  }

  // MARK: - Template-method hooks (override in subclass)

  /// Payload returned by the subclass's initial REST call. Carries the
  /// session id + ephemeral token + anything the subclass needs to stash
  /// (e.g. coaching keeps the procedure for the current-step computed property).
  struct SessionStartPayload {
    let sessionId: String
    let ephemeralToken: EphemeralTokenResponse
  }

  /// Subclass hits the mode's `POST /session/start` endpoint, returns
  /// session id + ephemeral token. Called once from `startGeminiLiveSession`.
  func mintSession() async throws -> SessionStartPayload {
    fatalError("GeminiLiveSessionBase.mintSession() must be overridden")
  }

  /// URL suffix for POST tool-call forwarding. Default targets the learner
  /// namespace; diagnostic overrides with `/api/troubleshoot/...`.
  var toolCallURLSuffix: String {
    guard let sid = sessionId else { return "/api/learner/session//tool-call" }
    return "/api/learner/session/\(sid)/tool-call"
  }

  /// Round-trip timeout for tool-call forwarding. Coaching's three tools
  /// return in <1s; diagnostic's `generate_sop_from_manual` takes 30-60s
  /// for PDF ingest.
  var toolCallTimeoutSeconds: TimeInterval { 10 }

  /// First synthetic user turn seeded on the initial `.connected` transition.
  /// Returning nil skips the seed (the user must speak first).
  var introSeedText: String? { nil }

  /// Fires after the base's `onTurnComplete` bookkeeping. Coaching uses this
  /// to reschedule heartbeats; other modes leave it as a no-op.
  func onTurnCompleteExtra() async {}

  /// Called after every tool call completes. Subclass updates its
  /// mode-specific state (step index, phase, resolution, etc.) before the
  /// tool-response ACK is sent back to Gemini. Runs on @MainActor so state
  /// mutations are safe.
  func handleToolCallExtras(name: String, args: [String: Any], result: [String: Any]) async {}

  /// Audio-session mode for the current transport. Coaching picks
  /// `.coaching` with HFP glasses or `.coachingPhoneOnly` with iPhone.
  /// Default `.coachingPhoneOnly` works for iPhone-only modes.
  var audioSessionMode: AudioSessionMode { .coachingPhoneOnly }

  /// Which camera transport to drive. Default iPhone. Coaching overrides
  /// to its stored `transport` property.
  var transport: CaptureTransport { .iPhone }

  /// Context summary injected after a successful resumption reconnect.
  /// Coaching fetches the learner-session summary; other modes return nil
  /// (the reconnect still happens, just without the re-orient).
  func contextSummaryForReconnect() async -> String? { nil }

  /// Wrapping text around the summary when re-injecting on a resumption
  /// reconnect. Default matches the original learner wording. Subclasses
  /// can override for mode-specific phrasing.
  func resumptionInjectText(summary: String) -> String {
    return "Session resumed after a brief interruption. Current coaching context:\n\(summary)"
  }

  /// Called at the very top of `stopGeminiLiveSession`, BEFORE the base's
  /// teardown sequence. Coaching uses this to cancel its heartbeat scheduler
  /// before Combine subs drop (so an in-flight Task.sleep can't wake up
  /// into a half-torn-down service).
  func willStopGeminiLiveSession() {}

  /// Called at the very end of `stopGeminiLiveSession`, after all services
  /// have been nilled. Subclass hook for any final mode-local cleanup.
  func didEndSession() {}

  // MARK: - Public control

  func toggleMute() {
    isMuted.toggle()
    isSendingAudio = !isMuted
    if isMuted {
      voiceStatus = "Muted"
    } else if geminiConnectionState == .connected {
      voiceStatus = "Listening"
    }
  }

  func retryGemini() {
    Task { await reconnectWithResumption(reason: "user retry") }
  }

  // MARK: - Session lifecycle

  /// Brings up audio + camera + WebSocket and wires callbacks. Called by
  /// the subclass's public `startSession(...)` after it has reset its own
  /// mode-specific state.
  func startGeminiLiveSession() async {
    // 1. Audio — pick the mode based on transport override.
    let audio = AudioSessionManager(mode: audioSessionMode)
    self.audioManager = audio

    let micGranted = await audio.requestMicrophonePermission()
    guard micGranted else {
      voiceStatus = "Mic denied"
      print("[GeminiLive] Microphone permission denied")
      return
    }

    // 2. Camera — glasses or iPhone depending on transport.
    switch transport {
    case .glasses:
      setupCameraStream()
    case .iPhone:
      setupIPhoneCameraStream()
    }

    // 3. Mint session via subclass.
    voiceStatus = "Starting session..."
    let payload: SessionStartPayload
    do {
      payload = try await mintSession()
    } catch {
      voiceStatus = "Session error"
      print("[GeminiLive] Failed to mint session: \(error)")
      return
    }
    self.sessionId = payload.sessionId

    // 4. Token manager.
    let tm = GeminiTokenManager(
      sessionId: payload.sessionId,
      serverBaseURL: serverBaseURL
    )
    await tm.setInitialToken(payload.ephemeralToken)
    self.tokenManager = tm

    // 5. Gemini Live service + shared callbacks.
    let gemini = GeminiLiveService(tokenManager: tm)
    self.geminiService = gemini

    gemini.onAudioData = { [weak self] data in
      self?.audioManager?.playPcm16Audio(data)
    }

    gemini.onTurnComplete = { [weak self] in
      Task { @MainActor in
        guard let self = self else { return }
        self.isAISpeaking = false
        self.assistantTurnOpen = false
        self.learnerTurnOpen = false
        if !self.isMuted {
          self.voiceStatus = "Listening"
        }
        await self.onTurnCompleteExtra()
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
        print("[GeminiLive] Barge-in → clearing playback buffer")
        self?.audioManager?.clearPlaybackBuffer(reason: "barge-in")
      }
    }

    observeGeminiConnectionState(gemini)

    // Audio mic-tap → Gemini (same three-gate check as before).
    audio.onAudioBuffer = { [weak self] buffer, _ in
      guard let self = self else { return }
      let sendingOk = self.isSendingAudio
      let noTool = self.pendingToolCallIds.isEmpty
      let ready = self.isGeminiReady
      let gateOpen = sendingOk && noTool && ready

      if gateOpen != self.audioGateWasOpen {
        self.audioGateWasOpen = gateOpen
        if gateOpen {
          print("[GeminiLive] Audio send gate OPEN — mic → Gemini live")
        } else {
          let reason: String
          if !ready { reason = "Gemini not ready" }
          else if !noTool { reason = "pending tool call" }
          else { reason = "muted" }
          print("[GeminiLive] Audio send gate CLOSED — \(reason)")
        }
      }

      guard gateOpen else { return }
      guard let pcmData = self.audioManager?.convertBufferForSend(buffer) else { return }

      Task {
        try? await self.geminiService?.sendAudio(pcmData)
      }
    }

    // 6. Connect. Setup-complete flips state to .connected inside the service;
    // our observer (below) picks that up and gates the audio send path open.
    voiceStatus = "Connecting..."
    await gemini.connect()

    // 7. Start audio capture (also starts playback).
    audio.startCapture()

    // Mirror audio manager's isAISpeaking onto the VM via Combine.
    observeAudioIsAISpeaking(audio)
  }

  /// Canonical teardown order — see inline comments. Order matters:
  ///   1. Close audio send gate so mic closures stop queueing into a dying WS.
  ///   2. Drop Combine subs so no state handler re-enters mid-teardown.
  ///   3. Stop audio capture BEFORE disconnecting Gemini — no races on WS close.
  ///   4. Disconnect Gemini, then nil services so callbacks can't reach a dead socket.
  ///   5. Wipe per-session state so subsequent startSession() starts clean.
  func stopGeminiLiveSession() {
    willStopGeminiLiveSession()
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
    hasSeededIntro = false
    voiceStatus = "Ended"
    geminiConnectionState = .disconnected

    didEndSession()
  }

  // MARK: - Camera Stream (glasses via DAT SDK)

  func setupCameraStream() {
    let prior = cameraLifecycleTask
    cameraLifecycleTask = Task { [weak self] in
      await prior?.value
      guard let self = self else { return }

      // Defensive: tear down a prior session before creating a new one.
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
          print("[GeminiLive] Could not attach stream capability to the device session")
          return
        }
        stream = s
      } catch {
        print("[GeminiLive] Failed to create glasses stream session: \(error)")
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
        print("[GeminiLive] Failed to start device session: \(error)")
        return
      }
      await stream.start()
    }
  }

  /// iPhone-native video source. Throttled at the shared 0.5 fps / 0.5 quality
  /// so the token budget math carries over from the glasses path.
  func setupIPhoneCameraStream() {
    let prior = cameraLifecycleTask
    cameraLifecycleTask = Task { [weak self] in
      await prior?.value
      guard let self = self else { return }

      self.iPhoneCamera?.onSampleBuffer = nil
      self.iPhoneCamera?.stop()
      self.iPhoneCamera = nil
      self.iPhoneVideoSource = nil

      let camera = IPhoneCameraCapture()
      let granted = await camera.requestPermission()
      guard granted else {
        self.voiceStatus = "Camera denied"
        print("[GeminiLive] iPhone camera permission denied")
        return
      }

      let source = IPhoneCoachingCameraSource(
        minInterval: self.videoMinInterval,
        jpegQuality: self.videoJpegQuality
      ) { [weak self] jpeg in
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
        print("[GeminiLive] iPhone camera failed to start: \(error)")
        return
      }
      self.iPhoneCamera = camera
    }
  }

  /// Enqueue camera teardown onto the lifecycle chain. Safe to call while a
  /// prior setup Task is still running — this one awaits it first, so start
  /// and stop never race for the same streamSession / iPhoneCamera refs.
  func stopCameraStream() {
    let prior = cameraLifecycleTask
    cameraLifecycleTask = Task { [weak self] in
      await prior?.value
      guard let self = self else { return }

      self.videoFrameListenerToken = nil
      self.stateListenerToken = nil

      if let session = self.streamSession {
        await session.stop()
      }
      self.deviceSession?.stop()
      self.streamSession = nil
      self.deviceSession = nil

      self.iPhoneCamera?.onSampleBuffer = nil
      self.iPhoneCamera?.stop()
      self.iPhoneCamera = nil
      self.iPhoneVideoSource = nil
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

  // MARK: - Tool call

  private func handleToolCall(id: String, name: String, args: [String: Any]) async {
    guard let sid = sessionId else { return }

    pendingToolCallIds.insert(id)
    audioManager?.clearPlaybackBuffer(reason: "tool-call")

    let startedAt = Date()
    print("[GeminiLive] ▶ Tool call START name=\(name) id=\(id) args=\(args)")

    let result = await forwardToolCallToServer(
      sessionId: sid,
      toolCallId: id,
      functionName: name,
      args: args
    )
    let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
    print("[GeminiLive] ◀ Tool call DONE  name=\(name) id=\(id) result=\(result) (\(elapsedMs)ms)")

    // Let the subclass react to the result (update step index, phase, etc.)
    // BEFORE we ACK the tool back to Gemini, so any dependent UI state has
    // flipped by the time Gemini asks follow-up questions.
    await handleToolCallExtras(name: name, args: args, result: result)

    appendToolCall(name: name, args: args, result: result)

    do {
      try await geminiService?.sendToolResponse(id: id, name: name, response: result)
      print("[GeminiLive] ✓ Tool response ACK sent to Gemini name=\(name) id=\(id)")
    } catch {
      print("[GeminiLive] ✗ Failed to send tool response name=\(name) id=\(id): \(error)")
    }

    pendingToolCallIds.remove(id)
  }

  private func forwardToolCallToServer(
    sessionId: String,
    toolCallId: String,
    functionName: String,
    args: [String: Any]
  ) async -> [String: Any] {
    guard let url = URL(string: "\(serverBaseURL)\(toolCallURLSuffix)") else {
      return ["error": "Invalid URL", "retryable": false]
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = toolCallTimeoutSeconds

    let body: [String: Any] = [
      "tool_name": functionName,
      "arguments": args,
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let http = response as? HTTPURLResponse else {
        print("[GeminiLive] Tool call: non-HTTP response")
        return [
          "error": "transient_network_failure",
          "message": "No HTTP response from server",
          "retryable": true,
        ]
      }

      guard (200...299).contains(http.statusCode) else {
        let bodySnippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
        print("[GeminiLive] Tool call failed: HTTP \(http.statusCode) body=\(bodySnippet)")
        return [
          "error": "server_rejected_tool_call",
          "message": "HTTP \(http.statusCode): \(bodySnippet)",
          "retryable": http.statusCode >= 500,
        ]
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let inner = json["result"] as? [String: Any] {
          return inner
        }
        return json
      }
      return ["status": "ok"]
    } catch {
      print("[GeminiLive] Tool call forward error: \(error)")
      return [
        "error": "transient_network_failure",
        "message": error.localizedDescription,
        "retryable": true,
      ]
    }
  }

  // MARK: - Activity feed

  func appendTranscript(kind: ActivityEntry.Kind, delta: String) {
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
    learnerTurnOpen = false
    assistantTurnOpen = false
    trimActivity()
  }

  /// Default summary is the raw tool name. Coaching overrides to render
  /// richer text ("Advanced to step 3: Remove the drip tray").
  func toolCallSummary(name: String, args: [String: Any], result: [String: Any]) -> String {
    return name
  }

  func trimActivity() {
    if activity.count > activityMaxEntries {
      activity.removeFirst(activity.count - activityMaxEntries)
    }
  }

  // MARK: - Connection state + intro seed

  private func observeGeminiConnectionState(_ gemini: GeminiLiveService) {
    gemini.$connectionState
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        guard let self = self else { return }
        print("[GeminiLive] Connection state → \(state)")
        self.geminiConnectionState = state
        switch state {
        case .connected:
          self.isGeminiReady = true
          self.voiceStatus = self.isMuted ? "Muted" : "Listening"
          print("[GeminiLive] Gemini Live connected")
          self.sendIntroSeedIfNeeded()
          // Subclasses that want a turnComplete-scheduled heartbeat rely on
          // onTurnCompleteExtra; they can also kick-start via the subclass's
          // .connected handler if needed — see coaching's override.
          self.onConnectedExtra()
        case .connecting:
          self.isGeminiReady = false
          self.voiceStatus = "Connecting..."
        case .error(let msg):
          self.isGeminiReady = false
          self.voiceStatus = "Connection error"
          print("[GeminiLive] Gemini Live error: \(msg)")
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

  /// Fires after the base's .connected transition. Coaching overrides to
  /// start its heartbeat scheduler. Other modes leave as no-op.
  func onConnectedExtra() {}

  private func sendIntroSeedIfNeeded() {
    guard !hasSeededIntro, let seedText = introSeedText else { return }
    hasSeededIntro = true
    Task { [weak self] in
      guard let self = self, let gemini = self.geminiService else { return }
      do {
        try await gemini.sendClientTextTurn(seedText)
        print("[GeminiLive] Seeded intro turn on first .connected")
      } catch {
        print("[GeminiLive] Failed to seed intro turn: \(error)")
      }
    }
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

  // MARK: - Resumption

  /// Reopen the WebSocket with the most recent resumption handle, then
  /// optionally inject a context summary from the subclass. Falls back to
  /// a plain token refresh + retry when no handle is yet available.
  func reconnectWithResumption(reason: String) async {
    guard !isResuming else {
      print("[GeminiLive] Reconnect requested (\(reason)) but already resuming")
      return
    }
    guard let tm = tokenManager, let gemini = geminiService, sessionId != nil else {
      return
    }
    guard let handle = resumptionHandle else {
      print("[GeminiLive] Reconnect (\(reason)): no handle yet, refreshing token + retrying")
      do {
        _ = try await tm.forceRefresh()
      } catch {
        print("[GeminiLive] Plain-retry token refresh failed: \(error)")
        voiceStatus = "Connection error"
        return
      }
      await gemini.retry()
      return
    }

    isResuming = true
    voiceStatus = "Reconnecting…"
    print("[GeminiLive] Reconnecting with resumption handle (\(reason))")

    do {
      _ = try await tm.forceRefresh(handle: handle)
    } catch {
      print("[GeminiLive] Resumption token mint failed: \(error)")
      voiceStatus = "Connection error"
      isResuming = false
      return
    }

    await gemini.retry()

    let deadline = Date().addingTimeInterval(5.0)
    while gemini.connectionState != .connected, Date() < deadline {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }

    guard gemini.connectionState == .connected else {
      print("[GeminiLive] Resumed socket did not open in 5s; aborting summary inject")
      isResuming = false
      return
    }

    if let summary = await contextSummaryForReconnect() {
      do {
        try await gemini.sendClientTextTurn(resumptionInjectText(summary: summary))
        print("[GeminiLive] Resumed — injected context summary")
      } catch {
        print("[GeminiLive] Failed to inject context summary: \(error)")
      }
    }

    isResuming = false
  }
}
