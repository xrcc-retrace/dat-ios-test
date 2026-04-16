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

  private let tokenManager: GeminiTokenManager
  private var webSocketTask: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private let maxAuthRetries = 2

  // MARK: - Callbacks

  /// Called when decoded PCM audio data is received from Gemini.
  var onAudioData: ((Data) -> Void)?

  /// Called when Gemini issues a tool call (function call).
  var onToolCall: ((_ id: String, _ name: String, _ args: [String: Any]) -> Void)?

  /// Called when Gemini signals a turn is complete (done speaking).
  var onTurnComplete: (() -> Void)?

  /// Called for raw text messages (for debugging or unhandled messages).
  var onMessage: ((URLSessionWebSocketTask.Message) -> Void)?

  init(tokenManager: GeminiTokenManager) {
    self.tokenManager = tokenManager
  }

  // MARK: - Public

  func connect() async {
    connectionState = .connecting

    do {
      let token = try await tokenManager.validToken()
      try await establishConnection(token: token)
      connectionState = .connected
      startReceiveLoop()
    } catch {
      connectionState = .error(error.localizedDescription)
    }
  }

  func disconnect() {
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    connectionState = .disconnected
  }

  /// Send raw PCM16 16kHz mono audio to Gemini Live as a base64-encoded JSON message.
  func sendAudio(_ pcmData: Data) async throws {
    let base64 = pcmData.base64EncodedString()
    let json: [String: Any] = [
      "realtimeInput": [
        "mediaChunks": [
          [
            "mimeType": "audio/pcm;rate=16000",
            "data": base64,
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

  private func establishConnection(token: EphemeralTokenResponse) async throws {
    guard let url = URL(string: token.websocketUrl) else {
      throw LiveServiceError.invalidURL
    }

    let session = URLSession(configuration: .default)
    let task = session.webSocketTask(with: url)
    task.resume()

    // Send an initial ping to verify the connection is alive.
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      task.sendPing { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
    webSocketTask = task
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
            onAudioData?(audioData)
          }
        }
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
        onToolCall?(id, name, args)
      }
    }

    // Handle setup complete (no action needed for constrained endpoint)
    if json["setupComplete"] != nil {
      print("[GeminiLive] Setup complete received")
    }
  }

  private func handleConnectionError(_ error: Error) async {
    for attempt in 1...maxAuthRetries {
      connectionState = .connecting

      do {
        let freshToken = try await tokenManager.forceRefresh()
        try await establishConnection(token: freshToken)
        connectionState = .connected
        startReceiveLoop()
        return
      } catch {
        if attempt == maxAuthRetries {
          connectionState = .error(
            "Reconnection failed after \(maxAuthRetries) attempts: \(error.localizedDescription)")
          return
        }
        try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
      }
    }
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
