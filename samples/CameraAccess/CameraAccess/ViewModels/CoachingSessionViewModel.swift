import MWDATCamera
import MWDATCore
import SwiftUI

@MainActor
class CoachingSessionViewModel: ObservableObject {
  @Published var currentStepIndex = 0
  @Published var currentVideoFrame: UIImage?
  @Published var isCompleted = false
  @Published var isMuted = false
  @Published var showPiP = false
  @Published var voiceStatus = "Connecting..."
  @Published var isAISpeaking = false
  @Published var geminiConnectionState: GeminiLiveService.ConnectionState = .disconnected

  private let procedure: ProcedureResponse
  private let wearables: WearablesInterface
  private let serverBaseURL: String
  private var streamSession: StreamSession?
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var sessionStartTime: Date?
  private var sessionRecordId: String?

  // Audio + Gemini Live
  private var audioManager: AudioSessionManager?
  private var geminiService: GeminiLiveService?
  private var tokenManager: GeminiTokenManager?
  private var sessionId: String?
  private var isSendingAudio = true
  private var pendingToolCallId: String?  // non-nil while waiting for server tool response

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
    stopCameraStream()
    stopGeminiLiveSession()
  }

  func advanceStep(progressStore: LocalProgressStore) {
    guard currentStepIndex < procedure.steps.count - 1 else {
      isCompleted = true
      if let recordId = sessionRecordId {
        progressStore.updateSession(
          id: recordId, stepsCompleted: procedure.steps.count, status: .completed)
      }
      stopCameraStream()
      stopGeminiLiveSession()
      return
    }

    currentStepIndex += 1
    if let recordId = sessionRecordId {
      progressStore.updateSession(
        id: recordId, stepsCompleted: currentStepIndex, status: .inProgress)
    }
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

    // Observe audio manager's isAISpeaking
    audio.onAudioBuffer = { [weak self] buffer, _ in
      guard let self = self else { return }
      // Only send if not muted and no pending tool call
      guard self.isSendingAudio, self.pendingToolCallId == nil else { return }

      guard let pcmData = self.audioManager?.convertBufferForSend(buffer) else { return }

      Task {
        try? await self.geminiService?.sendAudio(pcmData)
      }
    }

    // 5. Connect to Gemini Live
    voiceStatus = "Connecting..."
    await gemini.connect()

    geminiConnectionState = gemini.connectionState
    switch gemini.connectionState {
    case .connected:
      voiceStatus = "Listening"
      print("[Coaching] Gemini Live connected")
    case .error(let msg):
      voiceStatus = "Connection error"
      print("[Coaching] Gemini Live error: \(msg)")
    default:
      break
    }

    // 6. Start audio capture (this also starts playback)
    audio.startCapture()

    // Observe connection state changes
    observeGeminiState()
  }

  private func stopGeminiLiveSession() {
    geminiService?.disconnect()
    audioManager?.stopCapture()
    geminiService = nil
    audioManager = nil
    tokenManager = nil
    sessionId = nil
    pendingToolCallId = nil
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
    audioManager?.clearPlaybackBuffer()

    print("[Coaching] Tool call: \(name) (id: \(id), args: \(args))")

    // Forward to server
    let result = await forwardToolCallToServer(
      sessionId: sessionId,
      toolCallId: id,
      functionName: name,
      args: args
    )

    // Update local state based on tool call
    switch name {
    case "advance_step":
      if let stepData = result["current_step"] as? [String: Any],
         let stepNumber = stepData["step_number"] as? Int {
        currentStepIndex = stepNumber - 1  // 0-indexed
      }
      if let status = result["status"] as? String, status == "completed" {
        isCompleted = true
      }

    case "get_reference_clip":
      showPiP = true

    case "go_to_step":
      if let stepData = result["current_step"] as? [String: Any],
         let stepNumber = stepData["step_number"] as? Int {
        currentStepIndex = stepNumber - 1
      }

    default:
      break
    }

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
    let deviceSelector = AutoDeviceSelector(wearables: wearables)
    let config = StreamSessionConfig(
      videoCodec: .raw,
      resolution: .low,
      frameRate: 24
    )
    let session = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)
    self.streamSession = session

    videoFrameListenerToken = session.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        if let image = videoFrame.makeUIImage() {
          self?.currentVideoFrame = image
        }
      }
    }

    Task {
      await session.start()
    }
  }

  private func stopCameraStream() {
    Task {
      await streamSession?.stop()
    }
    streamSession = nil
    stateListenerToken = nil
    videoFrameListenerToken = nil
  }
}
