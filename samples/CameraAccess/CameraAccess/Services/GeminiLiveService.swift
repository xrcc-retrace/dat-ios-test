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

  // MARK: - Stats timer

  private func startStatsTimer() {
    guard statsTask == nil else { return }
    statsTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 s
        if Task.isCancelled { return }
        self?.flushStats()
      }
    }
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
  }

  private func flushStats() {
    if audioOutChunks > 0 {
      print(
        "[GeminiLive] Audio out: \(audioOutChunks) chunks / \(audioOutBytes) bytes in last 5s"
      )
    }
    if audioInChunks > 0 {
      print(
        "[GeminiLive] Audio in: \(audioInChunks) chunks / \(audioInBytes) bytes in last 5s"
      )
    }
    audioOutChunks = 0
    audioOutBytes = 0
    audioInChunks = 0
    audioInBytes = 0
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
    print("[GeminiLive] Video frame sent (\(jpegData.count) bytes, total=\(videoFramesSent))")
  }

  /// Send a synthetic user text turn. Used after session resumption to inject
  /// a context-summary message so the model re-orients on the current step.
  func sendClientTextTurn(_ text: String) async throws {
    let json: [String: Any] = [
      "clientContent": [
        "turns": [
          [
            "role": "user",
            "parts": [["text": text]],
          ]
        ],
        "turnComplete": true,
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
      // First attempt uses cached token; retries force-refresh in case the
      // token itself is the problem.
      let token: EphemeralTokenResponse =
        reconnectAttempts > 0
        ? try await tokenManager.forceRefresh()
        : try await tokenManager.validToken()
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
    print("[GeminiLive] Setup frame sent, awaiting setupComplete")
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
      parseJsonMessage(text)
    case .data(let data):
      // Binary frames — treat as raw PCM audio
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
        print("[GeminiLive] turnComplete")
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

      // Incremental transcription for learner mic and Gemini reply
      if let input = serverContent["inputTranscription"] as? [String: Any],
         let text = input["text"] as? String, !text.isEmpty {
        print("[GeminiLive] transcript/in: \"\(truncatedForLog(text))\"")
        onInputTranscript?(text)
      }
      if let output = serverContent["outputTranscription"] as? [String: Any],
         let text = output["text"] as? String, !text.isEmpty {
        print("[GeminiLive] transcript/out: \"\(truncatedForLog(text))\"")
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
    // drop or goAway. We store the most recent handle verbatim.
    if let update = json["sessionResumptionUpdate"] as? [String: Any],
       let handle = update["newHandle"] as? String, !handle.isEmpty {
      print("[GeminiLive] resumption handle updated (len=\(handle.count))")
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
