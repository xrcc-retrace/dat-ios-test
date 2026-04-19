import Foundation

/// Manages the WebSocket connection to Gemini Live API.
/// Handles token-based auth, automatic retry on auth failure,
/// and the JSON-based Gemini Live wire protocol.
@MainActor
class GeminiLiveService: ObservableObject {
  enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
  }

  @Published var connectionState: ConnectionState = .disconnected

  /// Latest `sessionResumptionUpdate.newHandle` from Gemini. Persist this to
  /// reopen the session with compressed context intact after GoAway or drops.
  @Published private(set) var resumptionHandle: String?

  private let tokenManager: GeminiTokenManager
  private var urlSession: URLSession?
  private var webSocketTask: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var delegateAdapter: WebSocketDelegateAdapter?

  private var reconnectAttempts: Int = 0
  private let maxReconnectAttempts: Int = 2

  // Diagnostic — cap how many initial binary frames we hex-dump so we can
  // identify the wire format without spamming the console once real audio flows.
  private var binaryFramesLogged = 0
  private let binaryFramesLogLimit = 5

  // MARK: - Callbacks

  /// Called when decoded PCM audio data is received from Gemini.
  var onAudioData: ((Data) -> Void)?

  /// Called when Gemini issues a tool call (function call).
  var onToolCall: ((_ id: String, _ name: String, _ args: [String: Any]) -> Void)?

  /// Called when Gemini signals a turn is complete (done speaking).
  var onTurnComplete: (() -> Void)?

  /// Called with incremental transcription of the learner's microphone audio.
  var onInputTranscript: ((String) -> Void)?

  /// Called with incremental transcription of Gemini's spoken reply.
  var onOutputTranscript: ((String) -> Void)?

  /// Called every time Gemini issues a fresh `sessionResumptionUpdate.newHandle`.
  /// Persist the handle so we can reopen the session later.
  var onResumptionUpdate: ((String) -> Void)?

  /// Called when Gemini sends a `goAway` announcing imminent WebSocket shutdown
  /// (~60 s before termination). The VM uses this to mint a resumption token
  /// and reopen the socket cleanly.
  var onGoAway: ((TimeInterval) -> Void)?

  /// Called when Gemini's server-side VAD detects the learner talking over the
  /// model (barge-in). The VM must stop playback and drain the queue so the
  /// learner doesn't hear the old reply continuing.
  var onInterrupted: (() -> Void)?

  /// Called for raw text messages (for debugging or unhandled messages).
  var onMessage: ((URLSessionWebSocketTask.Message) -> Void)?

  // MARK: - Observability counters (flushed every 5 s while connected)

  private var audioOutChunks = 0
  private var audioOutBytes = 0
  private var audioInChunks = 0
  private var audioInBytes = 0
  private var videoFramesSent = 0
  private var firstAudioSentLogged = false
  private var firstAudioReceivedLogged = false
  private var statsTask: Task<Void, Never>?

  /// Last `usageMetadata.totalTokenCount` observed from Gemini. Drops of
  /// >30k between consecutive samples are a strong signal that context
  /// window compression fired server-side (trigger=100k → target=40k).
  private var lastTokenCount: Int?
  private var lastLoggedTokenBand: Int = -1

  init(tokenManager: GeminiTokenManager) {
    self.tokenManager = tokenManager
  }

  // MARK: - Public

  func connect() async {
    reconnectAttempts = 0
    startStatsTimer()
    await performConnect()
  }

  /// User-initiated retry after a terminal `.error` state.
  ///
  /// Uses the token the TokenManager currently holds — callers that need a
  /// specific token (e.g. `reconnectWithResumption`, which mints a
  /// handle-baked token just prior to calling this) must set it via
  /// `tokenManager.forceRefresh(handle:)` before invoking `retry()`.
  ///
  /// If the cached token has already been consumed (uses=1 per Google docs),
  /// the initial handshake will fail and `handleConnectionError` will
  /// auto-retry with a fresh token on the next performConnect pass — costing
  /// one round-trip but preserving the "fresh-then-fallback" invariant.
  func retry() async {
    reconnectAttempts = 0
    startStatsTimer()
    await performConnect()
  }

  func disconnect() {
    tearDownConnection()
    stopStatsTimer()
    connectionState = .disconnected
  }

  // MARK: - Stats

  /// Previously printed `[GeminiLive] Audio out/in: N chunks …` every 5s.
  /// Removed as noise once the first-chunk logs confirmed bidirectional flow.
  /// Counters are still maintained (audioOutChunks etc.) for future UI use.

  private func startStatsTimer() {
    // No-op placeholder — kept so existing `connect()` call site still compiles
    // without having to thread state changes through the VM. Re-enable if a
    // real periodic stat readout is needed again.
  }

  private func stopStatsTimer() {
    statsTask?.cancel()
    statsTask = nil
    audioOutChunks = 0
    audioOutBytes = 0
    audioInChunks = 0
    audioInBytes = 0
    firstAudioSentLogged = false
    firstAudioReceivedLogged = false
    lastTokenCount = nil
    lastLoggedTokenBand = -1
  }

  /// Parse any `usageMetadata.totalTokenCount` in a server JSON message,
  /// log when the context crosses a new 10k band (so we see progression
  /// toward the 100k compression trigger), and flag a confirmed compression
  /// when the count drops by more than 30k between consecutive samples.
  private func observeUsageMetadata(_ json: [String: Any]) {
    let usage = (json["usageMetadata"] as? [String: Any])
      ?? (json["usage_metadata"] as? [String: Any])
    guard let usage,
          let totalAny = usage["totalTokenCount"] ?? usage["total_token_count"],
          let total = (totalAny as? Int) ?? (totalAny as? NSNumber)?.intValue
    else { return }

    // Crossed a new 10k threshold? Log once per band so we see growth.
    let band = total / 10_000
    if band != lastLoggedTokenBand {
      lastLoggedTokenBand = band
      print("[GeminiLive] context: totalTokenCount=\(total) (band=\(band * 10)k)")
    }

    // Compression detection — trigger=100k → target=40k means a ~60k drop.
    if let prev = lastTokenCount, prev - total >= 30_000 {
      print("[GeminiLive] ⚡ Context window COMPRESSION fired: \(prev) → \(total) tokens (Δ=\(prev - total))")
      lastLoggedTokenBand = total / 10_000
    }
    lastTokenCount = total
  }

  /// Send raw PCM16 16kHz mono audio to Gemini Live.
  /// Wire format: canonical `realtimeInput.audio` blob (not the deprecated
  /// `mediaChunks` array form).
  func sendAudio(_ pcmData: Data) async throws {
    let base64 = pcmData.base64EncodedString()
    let json: [String: Any] = [
      "realtimeInput": [
        "audio": [
          "data": base64,
          "mimeType": "audio/pcm;rate=16000",
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    guard let text = String(data: data, encoding: .utf8) else {
      throw LiveServiceError.encodingFailed
    }
    try await sendText(text)

    audioOutChunks += 1
    audioOutBytes += pcmData.count
    if !firstAudioSentLogged {
      firstAudioSentLogged = true
      print("[GeminiLive] First audio chunk sent (\(pcmData.count) bytes)")
    }
  }

  /// Send a single JPEG-encoded video frame to Gemini Live.
  /// Call at a modest rate (≈0.5 fps) — Gemini Live is rate-limited on video input.
  /// Wire format: canonical `realtimeInput.video` blob (not the deprecated
  /// `mediaChunks` array form).
  func sendVideoFrame(_ jpegData: Data) async throws {
    let base64 = jpegData.base64EncodedString()
    let json: [String: Any] = [
      "realtimeInput": [
        "video": [
          "data": base64,
          "mimeType": "image/jpeg",
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    guard let text = String(data: data, encoding: .utf8) else {
      throw LiveServiceError.encodingFailed
    }
    try await sendText(text)

    videoFramesSent += 1
    // Log the first frame, then one in every 20 — enough to confirm video is
    // still flowing without spamming every ~2 s.
    if videoFramesSent == 1 || videoFramesSent % 20 == 0 {
      print("[GeminiLive] Video frames sent: \(videoFramesSent) (latest=\(jpegData.count) bytes)")
    }
  }

  /// Send a synthetic user text turn. Used at session start to seed an opener
  /// (so Gemini speaks first without the learner needing to prompt) and after
  /// session resumption to inject a context-summary message.
  ///
  /// Wire format is `realtimeInput.text` — NOT `clientContent.turns`.
  /// On `gemini-3.1-flash-live-preview`, `clientContent` is silently dropped
  /// for live user input; it's reserved for pre-seeding conversation history.
  /// Sending the intro via `clientContent` left the model in a wedged state
  /// that 1008'd ("Operation is not implemented") the moment it tried to
  /// generate its first audio reply. Verified 2026-04-17:
  ///   • `realtimeInput.text` → 24 audio modelTurn frames received ✅
  ///   • `clientContent` → silent → 1008 on first response attempt ❌
  func sendClientTextTurn(_ text: String) async throws {
    let json: [String: Any] = [
      "realtimeInput": [
        "text": text,
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    guard let payload = String(data: data, encoding: .utf8) else {
      throw LiveServiceError.encodingFailed
    }
    try await sendText(payload)
  }

  /// Send a tool response back to Gemini after handling a function call.
  func sendToolResponse(id: String, name: String, response: [String: Any]) async throws {
    let json: [String: Any] = [
      "toolResponse": [
        "functionResponses": [
          [
            "id": id,
            "name": name,
            "response": response,
          ]
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    guard let text = String(data: data, encoding: .utf8) else {
      throw LiveServiceError.encodingFailed
    }
    try await sendText(text)
  }

  /// Send raw binary data.
  func sendMessage(_ data: Data) async throws {
    guard let ws = webSocketTask else {
      throw LiveServiceError.notConnected
    }
    try await ws.send(.data(data))
  }

  /// Send a text frame.
  func sendText(_ text: String) async throws {
    guard let ws = webSocketTask else {
      throw LiveServiceError.notConnected
    }
    try await ws.send(.string(text))
  }

  // MARK: - Private

  private func performConnect() async {
    tearDownConnection()
    connectionState = .connecting

    do {
      // First attempt uses cached token. Retries force-refresh to get a
      // fresh token. If we have a resumption handle from the prior
      // session (Gemini emits these periodically via
      // `sessionResumptionUpdate.newHandle`), pass it into the refresh so
      // the new token is baked with `SessionResumptionConfig(handle=…)`
      // and Gemini continues the prior session with compressed context
      // intact — instead of starting fresh and repeating the intro.
      let token: EphemeralTokenResponse
      if reconnectAttempts > 0 {
        let handle = resumptionHandle
        if let handle = handle {
          print("[GeminiLive] Reconnecting with resumption handle (len=\(handle.count))")
        } else {
          print("[GeminiLive] Reconnecting without resumption handle (none cached yet)")
        }
        token = try await tokenManager.forceRefresh(handle: handle)
      } else {
        token = try await tokenManager.validToken()
      }
      try establishConnection(token: token)
      startReceiveLoop()
      // .connected flips once the delegate reports a successful handshake.
    } catch {
      connectionState = .error(error.localizedDescription)
    }
  }

  private func tearDownConnection() {
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    urlSession?.invalidateAndCancel()
    urlSession = nil
    delegateAdapter = nil
    binaryFramesLogged = 0
  }

  private func establishConnection(token: EphemeralTokenResponse) throws {
    guard let url = URL(string: token.websocketUrl) else {
      print("[GeminiLive] Invalid WebSocket URL: \(token.websocketUrl)")
      throw LiveServiceError.invalidURL
    }

    print("[GeminiLive] Connecting to: \(url.host ?? "unknown")")

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30

    let adapter = WebSocketDelegateAdapter()
    adapter.onOpen = { [weak self] in
      Task { @MainActor [weak self] in
        self?.handleDidOpen()
      }
    }
    adapter.onClose = { [weak self] closeCode, reason in
      Task { @MainActor [weak self] in
        self?.handleDidClose(closeCode: closeCode, reason: reason)
      }
    }
    self.delegateAdapter = adapter

    let session = URLSession(configuration: config, delegate: adapter, delegateQueue: nil)
    self.urlSession = session

    let task = session.webSocketTask(with: url)
    task.resume()
    self.webSocketTask = task

    print("[GeminiLive] WebSocket task resumed, handshake in progress")
  }

  private func handleDidOpen() {
    print("[GeminiLive] WebSocket handshake complete — sending setup frame")
    // Constrained endpoint still requires a setup message as the very first
    // wire payload; without it the server closes with 1007 ("setup must be
    // the first message and only the first"). Config is already locked into
    // the ephemeral token, so an empty setup body is sufficient.
    // State stays at .connecting until we receive setupComplete back.
    Task { [weak self] in
      do {
        try await self?.sendSetupFrame()
      } catch {
        print("[GeminiLive] Failed to send setup frame: \(error)")
      }
    }
  }

  private func sendSetupFrame() async throws {
    let json: [String: Any] = ["setup": [String: Any]()]
    let data = try JSONSerialization.data(withJSONObject: json)
    guard let text = String(data: data, encoding: .utf8) else {
      throw LiveServiceError.encodingFailed
    }
    try await sendText(text)
    print("[GeminiLive] Setup frame sent (→ \(text.count) chars), awaiting setupComplete")
  }

  private func handleDidClose(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    print("[GeminiLive] WebSocket closed (code: \(closeCode.rawValue), reason: \(reasonStr))")
    // The receive loop will also observe the closure and call handleConnectionError.
  }

  private func startReceiveLoop() {
    receiveTask?.cancel()
    receiveTask = Task { [weak self] in
      await self?.receiveLoop()
    }
  }

  private func receiveLoop() async {
    guard let ws = webSocketTask else { return }

    while !Task.isCancelled {
      do {
        let message = try await ws.receive()
        handleMessage(message)
      } catch {
        if Task.isCancelled { return }
        await handleConnectionError(error)
        return
      }
    }
  }

  private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
    switch message {
    case .string(let text):
      // Log a head-only preview so we can see setupComplete / goAway / errors
      // arrive without dumping entire audio base64 payloads into the console.
      let head = String(text.prefix(160))
      let suffix = text.count > 160 ? "… (\(text.count) chars)" : ""
      print("[GeminiLive] ← string: \(head)\(suffix)")
      parseJsonMessage(text)
    case .data(let data):
      // The `BidiGenerateContentConstrained` endpoint (v1alpha ephemeral-token
      // variant of Gemini Live — see services/ephemeral_token.py on the server)
      // delivers JSON control messages as BINARY WebSocket frames (opcode 0x02)
      // rather than text frames. Verified on the wire: setupComplete arrives
      // here as the 26 bytes of `{"setupComplete":{}}` pretty-printed.
      //
      // Try to decode as UTF-8 JSON first. If it parses (or even just starts
      // with `{` / `[`), route to the JSON handler. Otherwise fall through to
      // the raw-PCM path for audio frames.
      if let text = String(data: data, encoding: .utf8),
         let first = text.first,
         first == "{" || first == "[" {
        parseJsonMessage(text)
        return
      }
      // Not JSON — treat as PCM audio. Keep diagnostic for the first few.
      if binaryFramesLogged < binaryFramesLogLimit {
        binaryFramesLogged += 1
        let preview = data.prefix(64)
        let hex = preview.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[GeminiLive] ← binary/pcm #\(binaryFramesLogged): \(data.count) bytes hex=\(hex)")
      }
      onAudioData?(data)
    @unknown default:
      break
    }

    // Forward to generic handler for debugging
    onMessage?(message)
  }

  private func parseJsonMessage(_ text: String) {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }

    // Token usage — surface context growth + detect compression.
    observeUsageMetadata(json)

    // Handle server content (model turn with audio, turn complete)
    if let serverContent = json["serverContent"] as? [String: Any] {
      // Barge-in: Gemini's server VAD detected the learner talking over the
      // model. It has cancelled generation; we must drain playback so the old
      // reply doesn't keep coming out of the glasses speaker.
      if let interrupted = serverContent["interrupted"] as? Bool, interrupted {
        print("[GeminiLive] Interrupted — server detected barge-in, clearing playback")
        onInterrupted?()
      }

      // Check for turn complete
      if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
        onTurnComplete?()
      }

      // Check for model turn with audio parts
      if let modelTurn = serverContent["modelTurn"] as? [String: Any],
         let parts = modelTurn["parts"] as? [[String: Any]] {
        for part in parts {
          if let inlineData = part["inlineData"] as? [String: Any],
             let base64String = inlineData["data"] as? String,
             let audioData = Data(base64Encoded: base64String) {
            audioInChunks += 1
            audioInBytes += audioData.count
            if !firstAudioReceivedLogged {
              firstAudioReceivedLogged = true
              print("[GeminiLive] First audio from Gemini (\(audioData.count) bytes)")
            }
            onAudioData?(audioData)
          }
        }
      }

      // Transcripts forward to the UI but aren't logged — the activity feed
      // already renders them, and per-word prints flooded the console.
      if let input = serverContent["inputTranscription"] as? [String: Any],
         let text = input["text"] as? String, !text.isEmpty {
        onInputTranscript?(text)
      }
      if let output = serverContent["outputTranscription"] as? [String: Any],
         let text = output["text"] as? String, !text.isEmpty {
        onOutputTranscript?(text)
      }
    }

    // Handle tool calls
    if let toolCall = json["toolCall"] as? [String: Any],
       let functionCalls = toolCall["functionCalls"] as? [[String: Any]] {
      for fc in functionCalls {
        guard let id = fc["id"] as? String,
              let name = fc["name"] as? String
        else { continue }
        let args = fc["args"] as? [String: Any] ?? [:]
        print("[GeminiLive] toolCall received: \(name) (id=\(id))")
        onToolCall?(id, name, args)
      }
    }

    // Setup complete — NOW the session is truly usable. Flip .connected here
    // (not in handleDidOpen) so the VM doesn't open the audio/video send gate
    // before Gemini is ready, which would trigger code 1007 ("setup must be
    // the first message") by sending realtimeInput before setupComplete.
    if json["setupComplete"] != nil {
      print("[GeminiLive] Setup complete — Gemini Live ready")
      connectionState = .connected
      reconnectAttempts = 0
    }

    // Session resumption handle — Gemini issues these periodically so the
    // client can reopen a session (with compressed context intact) after a
    // drop or goAway. BidiGenerateContentConstrained emits ~1-2/sec, so
    // dedup on the handle value to avoid redundant callbacks.
    if let update = json["sessionResumptionUpdate"] as? [String: Any],
       let handle = update["newHandle"] as? String, !handle.isEmpty,
       handle != resumptionHandle {
      resumptionHandle = handle
      onResumptionUpdate?(handle)
    }

    // GoAway — Gemini is closing this WebSocket soon (typically ~60 s warning).
    // Surface `timeLeft` so the VM can kick off a resumption-aware reconnect.
    if let goAway = json["goAway"] as? [String: Any] {
      let seconds: TimeInterval
      if let num = goAway["timeLeft"] as? NSNumber {
        seconds = num.doubleValue
      } else if let str = goAway["timeLeft"] as? String {
        // Gemini encodes durations as strings like "58s".
        let trimmed = str.trimmingCharacters(in: CharacterSet(charactersIn: "s"))
        seconds = TimeInterval(trimmed) ?? 0
      } else {
        seconds = 0
      }
      print("[GeminiLive] goAway received (timeLeft=\(seconds)s)")
      onGoAway?(seconds)
    }
  }

  private func handleConnectionError(_ error: Error) async {
    // If the caller has already disconnected, don't auto-reconnect.
    if case .disconnected = connectionState { return }

    print("[GeminiLive] Connection error: \(error.localizedDescription)")

    guard reconnectAttempts < maxReconnectAttempts else {
      connectionState = .error(
        "Connection lost after \(maxReconnectAttempts) retry attempts."
      )
      tearDownConnection()
      return
    }

    reconnectAttempts += 1
    connectionState = .connecting
    try? await Task.sleep(nanoseconds: UInt64(reconnectAttempts) * 500_000_000)
    await performConnect()
  }

  /// Compact a long transcript delta for console logging without dumping
  /// paragraphs into the log on every partial update.
  private func truncatedForLog(_ text: String, limit: Int = 60) -> String {
    let collapsed = text.replacingOccurrences(of: "\n", with: " ")
    guard collapsed.count > limit else { return collapsed }
    return String(collapsed.prefix(limit)) + "…"
  }

  enum LiveServiceError: LocalizedError {
    case notConnected
    case invalidURL
    case encodingFailed

    var errorDescription: String? {
      switch self {
      case .notConnected: return "Not connected to Gemini Live"
      case .invalidURL: return "Invalid WebSocket URL"
      case .encodingFailed: return "Failed to encode message"
      }
    }
  }
}

// MARK: - URLSessionWebSocketDelegate adapter

private final class WebSocketDelegateAdapter: NSObject, URLSessionWebSocketDelegate {
  var onOpen: (() -> Void)?
  var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    onOpen?()
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    onClose?(closeCode, reason)
  }
}
