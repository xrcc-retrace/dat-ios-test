import AVFoundation
import Foundation

/// How the AudioSessionManager should configure its AVAudioSession.
///
/// - `.coaching`: full-duplex with AEC and speaker fallback — Gemini Live voice
///   chat when glasses (BT HFP) are the preferred route if available.
/// - `.coachingPhoneOnly`: full-duplex with AEC + forced built-in mic +
///   loudspeaker. Used when the learner explicitly picked the iPhone transport
///   and we must ignore any connected HFP glasses.
/// - `.recording`: simplex capture — no playback, no AEC, no `.defaultToSpeaker`
///   override. Expert recording via glasses (HFP) or iPhone mic fallback.
/// - `.recordingPhoneOnly`: simplex capture, forced built-in mic. Used for
///   iPhone-native expert recording — ignores HFP even if glasses are paired.
enum AudioSessionMode {
  case coaching
  case coachingPhoneOnly
  case recording
  case recordingPhoneOnly
}

@MainActor
class AudioSessionManager: ObservableObject {
  @Published var isCapturing = false
  @Published var isBluetoothConnected = false
  @Published var isAISpeaking = false

  let mode: AudioSessionMode

  private let engine = AVAudioEngine()
  private var inputNode: AVAudioInputNode { engine.inputNode }

  // MARK: - Playback

  private let playerNode = AVAudioPlayerNode()
  private let playbackFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 24_000,
    channels: 1,
    interleaved: true
  )!

  /// Tracks scheduled buffers so we know when AI stops speaking.
  private var scheduledBufferCount = 0

  // MARK: - Observability

  private var captureBuffersSinceLastFlush = 0
  private var lastBufferReceivedAt: Date?
  private var silentMicWarned = false
  private var invalidFormatWarned = false
  private var playbackAllocFailures = 0
  private var statsTask: Task<Void, Never>?

  // MARK: - Send format (mic → Gemini)

  private let sendFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: true
  )!
  private var audioConverter: AVAudioConverter?
  /// Input format the current `audioConverter` was built against. Used to
  /// short-circuit route-change rebinds when the live format hasn't changed
  /// (see `rebindMicTapIfCapturing(reason:)`).
  private var converterInputFormat: AVAudioFormat?

  /// Called on the audio capture queue with each PCM buffer.
  var onAudioBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

  /// The actual hardware sample rate (read after configureAudioSession).
  var hardwareSampleRate: Double {
    AVAudioSession.sharedInstance().sampleRate
  }

  /// The hardware input format (read after configureAudioSession + engine prep).
  var inputFormat: AVAudioFormat {
    inputNode.inputFormat(forBus: 0)
  }

  init(mode: AudioSessionMode = .coaching) {
    self.mode = mode

    // Attach player node only for coaching modes. Recording has no playback
    // and attaching the node forces `.playAndRecord`, which pulls in output-port
    // negotiation and triggers the route-change cascade we're trying to avoid.
    if mode == .coaching || mode == .coachingPhoneOnly {
      engine.attach(playerNode)
      engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRouteChange),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Audio Session

  func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      switch mode {
      case .coaching:
        // Full-duplex with hardware AEC, speaker fallback when no HFP is paired.
        try session.setCategory(
          .playAndRecord,
          mode: .voiceChat,
          options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
      case .coachingPhoneOnly:
        // Full-duplex with AEC, forced to built-in mic + loudspeaker even when
        // HFP glasses are paired. The learner explicitly chose the iPhone transport.
        try session.setCategory(
          .playAndRecord,
          mode: .voiceChat,
          options: [.defaultToSpeaker]  // no HFP / A2DP
        )
      case .recording:
        // Simplex capture. No `.voiceChat` (no AEC processing), no `.defaultToSpeaker`
        // (nothing to play, and this option forces an override-to-speaker that
        // triggers the categoryChange cascade which detaches the mic tap).
        try session.setCategory(
          .record,
          mode: .default,
          options: [.allowBluetoothHFP, .allowBluetoothA2DP]
        )
      case .recordingPhoneOnly:
        // Simplex capture forced to the built-in mic. Ignores any paired HFP
        // glasses — the expert explicitly chose the iPhone transport.
        try session.setCategory(
          .record,
          mode: .default,
          options: []  // no HFP / A2DP
        )
      }
      try session.setActive(true)
      if mode == .coachingPhoneOnly {
        // Belt-and-suspenders: even with `.defaultToSpeaker`, an actively routed
        // HFP output could sneak through if the user paired glasses mid-session.
        // This override forces the loudspeaker for the life of this activation.
        try session.overrideOutputAudioPort(.speaker)
      }
      if mode == .coachingPhoneOnly || mode == .recordingPhoneOnly {
        forceBuiltInMicPreferred(session)
      }
      checkBluetoothRoute()
    } catch {
      print("[AudioSession] Failed to configure audio session: \(error)")
    }
  }

  /// Pin the AVAudioSession input to the built-in iPhone mic. Called only from
  /// the `*PhoneOnly` modes so HFP glasses (even if paired) don't steal the
  /// input route.
  private func forceBuiltInMicPreferred(_ session: AVAudioSession) {
    guard
      let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic })
    else {
      print("[AudioSession] ⚠ No built-in mic input available to pin")
      return
    }
    do {
      try session.setPreferredInput(builtIn)
    } catch {
      print("[AudioSession] Failed to pin built-in mic input: \(error)")
    }
  }

  // MARK: - Permissions

  func requestMicrophonePermission() async -> Bool {
    return await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  // MARK: - Capture

  /// Off-main variant of `startCapture()` used by the recording path. Moves
  /// the ~200 ms of `AVAudioSession` + `AVAudioEngine` setup onto a user-
  /// initiated background task so the UI thread doesn't freeze while the
  /// user waits for "Start recording" to flip. The sync `startCapture()`
  /// above is kept for the coaching-path call sites that already run inside
  /// larger async flows.
  func startCaptureAsync() async {
    guard !isCapturing else { return }

    let capturedMode = mode
    let capturedEngine = engine
    let capturedInputNode = inputNode

    // Phase 1 — heavy AVAudioSession setup off main.
    await Task.detached(priority: .userInitiated) {
      Self.configureSessionOffMain(mode: capturedMode)
      if capturedMode == .coaching || capturedMode == .coachingPhoneOnly {
        do {
          try capturedInputNode.setVoiceProcessingEnabled(true)
        } catch {
          print("[AudioSession] ⚠ Failed to enable voice processing: \(error)")
        }
      }
    }.value

    // Phase 2 — install the mic tap on main. The closure captures `self`
    // (MainActor) to reach `recordCapturedBuffer` / `onAudioBuffer`; doing
    // this hop on main matches the existing `installMicTap()` pattern and
    // avoids the @Sendable-vs-@MainActor closure friction that a detached
    // install would hit. The call itself is non-blocking (tap installation
    // is a few-µs operation on AVAudioInputNode), so it adds no visible lag.
    installMicTap()

    // Phase 3 — engine.start() is the other ~50–100 ms blocker; keep it
    // off main.
    let engineStarted: Bool = await Task.detached(priority: .userInitiated) {
      do {
        try capturedEngine.start()
        return true
      } catch {
        print("[AudioSession] Audio engine start error: \(error)")
        return false
      }
    }.value

    guard engineStarted else {
      inputNode.removeTap(onBus: 0)
      return
    }

    if capturedMode == .coaching || capturedMode == .coachingPhoneOnly {
      playerNode.play()
    }
    isCapturing = true

    initializeConverterIfNeeded()

    let inFmt = inputNode.inputFormat(forBus: 0)
    if inFmt.sampleRate == 0 || inFmt.channelCount == 0, !invalidFormatWarned {
      invalidFormatWarned = true
      print(
        "[AudioSession] ⚠ Invalid input format after engine start "
        + "(rate=\(inFmt.sampleRate), channels=\(inFmt.channelCount)) — "
        + "capture will be silent"
      )
    }

    checkBluetoothRoute()
    startStatsTimer()
  }

  /// Background-safe session setup called from `startCaptureAsync()`'s
  /// detached task. Mirrors the category/active/preferred-input work of
  /// `configureAudioSession()` without touching any `@Published` state, so
  /// it's safe to run off the main actor. `AVAudioSession` APIs are
  /// documented thread-safe.
  nonisolated private static func configureSessionOffMain(mode: AudioSessionMode) {
    let session = AVAudioSession.sharedInstance()
    do {
      switch mode {
      case .coaching:
        try session.setCategory(
          .playAndRecord,
          mode: .voiceChat,
          options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
      case .coachingPhoneOnly:
        try session.setCategory(
          .playAndRecord,
          mode: .voiceChat,
          options: [.defaultToSpeaker]
        )
      case .recording:
        try session.setCategory(
          .record,
          mode: .default,
          options: [.allowBluetoothHFP, .allowBluetoothA2DP]
        )
      case .recordingPhoneOnly:
        try session.setCategory(
          .record,
          mode: .default,
          options: []
        )
      }
      try session.setActive(true)
      if mode == .coachingPhoneOnly {
        try session.overrideOutputAudioPort(.speaker)
      }
      if mode == .coachingPhoneOnly || mode == .recordingPhoneOnly {
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
          do {
            try session.setPreferredInput(builtIn)
          } catch {
            print("[AudioSession] Failed to pin built-in mic input: \(error)")
          }
        }
      }
    } catch {
      print("[AudioSession] Failed to configure audio session: \(error)")
    }
  }

  func startCapture() {
    guard !isCapturing else { return }

    configureAudioSession()

    // For coaching modes, enable hardware voice processing on the input node —
    // acoustic echo cancellation + noise suppression + automatic gain control.
    // Required when the phone speaker plays Gemini's reply on loudspeaker while
    // the mic is open; without this, the mic picks up the speaker output, the
    // server-side VAD fires a barge-in, Gemini cuts its own reply, and the loop
    // repeats. `.voiceChat` mode alone is tuned for earpiece and doesn't cancel
    // loudspeaker well. `setVoiceProcessingEnabled(true)` must be called before
    // `engine.start()` and reconfigures the input node's output format.
    if mode == .coaching || mode == .coachingPhoneOnly {
      do {
        try inputNode.setVoiceProcessingEnabled(true)
      } catch {
        print("[AudioSession] ⚠ Failed to enable voice processing: \(error)")
      }
    }

    installMicTap()

    do {
      try engine.start()
      if mode == .coaching || mode == .coachingPhoneOnly {
        playerNode.play()
      }
      isCapturing = true

      // Lazily initialize audio converter now that we know the hardware format
      initializeConverterIfNeeded()

      // Flag a silent-capture failure mode early.
      let inFmt = inputNode.inputFormat(forBus: 0)
      if inFmt.sampleRate == 0 || inFmt.channelCount == 0, !invalidFormatWarned {
        invalidFormatWarned = true
        print(
          "[AudioSession] ⚠ Invalid input format after engine start "
          + "(rate=\(inFmt.sampleRate), channels=\(inFmt.channelCount)) — "
          + "capture will be silent"
        )
      }

      startStatsTimer()
    } catch {
      print("[AudioSession] Audio engine start error: \(error)")
      inputNode.removeTap(onBus: 0)
    }
  }

  /// Install the mic tap at the current input-node format.
  /// Safe to call repeatedly — removes any existing tap first.
  /// Used both at `startCapture()` time and when a route change alters
  /// the input format, so the tap stays bound to the live bus.
  private func installMicTap() {
    inputNode.removeTap(onBus: 0)
    // Use nil format to accept the hardware's native format; avoids format mismatch on BT HFP.
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
      guard let self = self else { return }
      self.recordCapturedBuffer(buffer)
      self.onAudioBuffer?(buffer, time)
    }
  }

  func stopCapture() {
    guard isCapturing else { return }
    inputNode.removeTap(onBus: 0)
    // Flush pending playback buffers FIRST so the player-node stop can't be
    // racing with a scheduled buffer callback (only applies to coaching modes).
    if mode == .coaching || mode == .coachingPhoneOnly {
      playerNode.stop()
      scheduledBufferCount = 0
    }
    engine.stop()
    isCapturing = false
    isAISpeaking = false
    scheduledBufferCount = 0
    onAudioBuffer = nil  // drop any capture handler so trailing taps can't fire
    stopStatsTimer()
    audioConverter = nil
    converterInputFormat = nil

    // Leave AVAudioSession in a state that plays nicely with whatever comes
    // next — review sheet's AVPlayer, another capture session, or idle.
    //
    // For recording modes: flip to `.playback` so AVPlayer in the review sheet
    // can play the just-captured file.
    // For coaching modes: also flip to `.playback`, then deactivate — otherwise
    // the session stays in `.playAndRecord/.voiceChat` with `.defaultToSpeaker`
    // and downstream audio gets stuck on the loudspeaker at phone-call volume.
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true)
    } catch {
      print("[AudioSession] Failed to switch to .playback: \(error)")
    }

    if mode == .coaching || mode == .coachingPhoneOnly {
      do {
        // `.notifyOthersOnDeactivation` wakes any other audio app we bumped
        // during `.voiceChat` so system routing snaps back cleanly.
        try session.setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        print("[AudioSession] Failed to deactivate: \(error)")
      }
    }
  }

  // MARK: - Capture telemetry

  /// Called from the tap thread on every captured buffer.
  /// Extract primitives here so we don't capture the non-Sendable
  /// `AVAudioPCMBuffer` into the main-actor hop closure.
  nonisolated private func recordCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
    let frames = buffer.frameLength
    let rate = buffer.format.sampleRate
    let channels = buffer.format.channelCount
    let commonFormat: String
    switch buffer.format.commonFormat {
    case .pcmFormatInt16: commonFormat = "Int16"
    case .pcmFormatFloat32: commonFormat = "Float32"
    case .pcmFormatInt32: commonFormat = "Int32"
    case .pcmFormatFloat64: commonFormat = "Float64"
    default: commonFormat = "other"
    }
    Task { @MainActor [weak self] in
      guard let self = self else { return }
      self.lastBufferReceivedAt = Date()
      self.captureBuffersSinceLastFlush += 1
      self.silentMicWarned = false  // buffers are flowing; re-arm watchdog
    }
  }

  private func startStatsTimer() {
    guard statsTask == nil else { return }
    statsTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 s
        if Task.isCancelled { return }
        self?.flushCaptureStats()
        self?.checkSilentMicWatchdog()
      }
    }
  }

  private func stopStatsTimer() {
    statsTask?.cancel()
    statsTask = nil
    captureBuffersSinceLastFlush = 0
    silentMicWarned = false
    invalidFormatWarned = false
    lastBufferReceivedAt = nil
    playbackAllocFailures = 0
  }

  private func flushCaptureStats() {
    guard isCapturing else { return }
    captureBuffersSinceLastFlush = 0
  }

  private func checkSilentMicWatchdog() {
    guard isCapturing, !silentMicWarned else { return }
    if let last = lastBufferReceivedAt,
       Date().timeIntervalSince(last) > 3.0 {
      silentMicWarned = true
      print(
        "[AudioSession] ⚠ No mic buffers for 3s — check BT HFP route or "
        + "glasses mic permission"
      )
    } else if lastBufferReceivedAt == nil,
              Date().timeIntervalSince(Date().addingTimeInterval(-3.0)) >= 0,
              captureBuffersSinceLastFlush == 0 {
      // Engine started but no first buffer ever arrived.
      silentMicWarned = true
      print(
        "[AudioSession] ⚠ No mic buffers since capture started — "
        + "check mic permission / hardware route"
      )
    }
  }

  // MARK: - Playback (PCM16LE 24kHz mono from Gemini)

  /// Play raw PCM16 Int16 audio data received from Gemini Live.
  /// Thread-safe — can be called from any thread. No-op in recording modes.
  func playPcm16Audio(_ data: Data) {
    guard mode == .coaching || mode == .coachingPhoneOnly else {
      print("[AudioSession] ⚠ playPcm16Audio called in recording mode — ignoring")
      return
    }
    let bytesPerFrame = 2  // Int16
    let frameCount = AVAudioFrameCount(data.count / bytesPerFrame)
    guard frameCount > 0 else {
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        self.playbackAllocFailures += 1
        if self.playbackAllocFailures == 1 {
          print("[AudioSession] ⚠ playPcm16Audio: zero-frame chunk (bytes=\(data.count))")
        }
      }
      return
    }

    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: playbackFormat,
      frameCapacity: frameCount
    ) else {
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        self.playbackAllocFailures += 1
        print(
          "[AudioSession] ⚠ Failed to allocate playback buffer "
          + "(frames=\(frameCount), total failures=\(self.playbackAllocFailures))"
        )
      }
      return
    }

    buffer.frameLength = frameCount
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      memcpy(buffer.int16ChannelData![0], base, data.count)
    }

    scheduledBufferCount += 1
    Task { @MainActor [weak self] in
      guard let self = self else { return }
      self.isAISpeaking = true
    }

    playerNode.scheduleBuffer(buffer) { [weak self] in
      guard let self = self else { return }
      Task { @MainActor in
        self.scheduledBufferCount -= 1
        if self.scheduledBufferCount <= 0 {
          self.scheduledBufferCount = 0
          self.isAISpeaking = false
        }
      }
    }
  }

  /// Flush all queued playback buffers and restart the player.
  func clearPlaybackBuffer(reason: String = "unspecified") {
    guard mode == .coaching || mode == .coachingPhoneOnly else {
      print("[AudioSession] ⚠ clearPlaybackBuffer called in recording mode — ignoring")
      return
    }
    playerNode.stop()
    scheduledBufferCount = 0
    isAISpeaking = false
    // Only re-prime the player if the engine is still running. Barge-in can
    // fire after stopCapture() has torn the engine down; calling
    // playerNode.play() on a stopped engine is a no-op that logs an
    // AVAudioEngine error (AVAudioPlayerNodeImpl.mm line-noise) without
    // any meaningful signal for the caller.
    if engine.isRunning {
      playerNode.play()
    }
  }

  // MARK: - Format Conversion (mic → PCM16 16kHz mono for Gemini)

  /// Convert a mic capture buffer to PCM16 16kHz mono Data for sending to Gemini.
  /// Returns nil if conversion fails.
  func convertBufferForSend(_ buffer: AVAudioPCMBuffer) -> Data? {
    guard let converter = audioConverter else {
      // Fallback: try to initialize now
      initializeConverterIfNeeded()
      guard let converter = audioConverter else { return nil }
      return convertWithConverter(converter, buffer: buffer)
    }
    return convertWithConverter(converter, buffer: buffer)
  }

  private func convertWithConverter(_ converter: AVAudioConverter, buffer: AVAudioPCMBuffer) -> Data? {
    let ratio = sendFormat.sampleRate / buffer.format.sampleRate
    let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
    guard outputFrameCount > 0 else { return nil }

    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: sendFormat,
      frameCapacity: outputFrameCount
    ) else { return nil }

    var error: NSError?
    var hasData = false

    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if hasData {
        outStatus.pointee = .noDataNow
        return nil
      }
      hasData = true
      outStatus.pointee = .haveData
      return buffer
    }

    if let error = error {
      print("[AudioSession] Audio conversion error: \(error)")
      return nil
    }

    guard outputBuffer.frameLength > 0 else { return nil }

    // Extract raw Int16 bytes
    let byteCount = Int(outputBuffer.frameLength) * 2  // Int16 = 2 bytes
    guard let channelData = outputBuffer.int16ChannelData else { return nil }
    return Data(bytes: channelData[0], count: byteCount)
  }

  private func initializeConverterIfNeeded() {
    guard audioConverter == nil else { return }
    let hwFormat = inputNode.inputFormat(forBus: 0)
    guard hwFormat.sampleRate > 0 else { return }
    audioConverter = AVAudioConverter(from: hwFormat, to: sendFormat)
    converterInputFormat = hwFormat
  }

  // MARK: - Route Monitoring

  @objc private func handleRouteChange(notification: Notification) {
    guard let info = notification.userInfo,
          let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
    else { return }

    let reasonLabel = routeChangeReasonLabel(reason)

    // NOTE: Do NOT call configureAudioSession() from inside a route-change handler.
    // Reconfiguring the session here triggers another categoryChange notification,
    // which cascades and can leave the mic tap orphaned from the live input format.
    // Let iOS own the routing; we just rebind the tap to the new input format.

    Task { @MainActor in
      self.checkBluetoothRoute()

      // Route changes that can alter the input format or invalidate the tap.
      // When capturing, drop the old tap, reinit the converter against the new
      // input format, and reinstall — so the tap stays bound to the live bus.
      switch reason {
      case .newDeviceAvailable,
           .oldDeviceUnavailable,
           .override,
           .categoryChange,
           .routeConfigurationChange:
        self.rebindMicTapIfCapturing(reason: reasonLabel)
      default:
        break
      }
    }
  }

  /// Re-bind the mic tap to the current input-node format after a route change.
  /// Safe no-op when we aren't capturing or the engine isn't running.
  ///
  /// Short-circuits when the live input format matches the format the converter
  /// was built against. This collapses the startup cascade where `setCategory`
  /// + `setActive` + `overrideOutputAudioPort` + `setPreferredInput` + engine
  /// start all queue route-change notifications that the run loop delivers
  /// *after* `startCapture()` returns — each previously rebuilt tap + converter
  /// against an unchanged format. Real route swaps (HFP ↔ built-in) change
  /// rate or channel count and still fall through to the rebuild path.
  private func rebindMicTapIfCapturing(reason: String) {
    guard isCapturing else { return }
    guard engine.isRunning else { return }

    let liveFmt = inputNode.inputFormat(forBus: 0)

    if let built = converterInputFormat,
       built.sampleRate == liveFmt.sampleRate,
       built.channelCount == liveFmt.channelCount,
       built.commonFormat == liveFmt.commonFormat {
      return
    }

    // Install at the new format. `installMicTap()` removes any existing tap first.
    installMicTap()

    // The hardware format changed (HFP ↔ built-in); rebuild the converter.
    audioConverter = nil
    converterInputFormat = nil
    initializeConverterIfNeeded()

    // Re-arm the silent-mic watchdog so it evaluates against the new route.
    silentMicWarned = false
    lastBufferReceivedAt = nil
  }

  private func routeChangeReasonLabel(_ reason: AVAudioSession.RouteChangeReason) -> String {
    switch reason {
    case .unknown: return "unknown"
    case .newDeviceAvailable: return "newDeviceAvailable"
    case .oldDeviceUnavailable: return "oldDeviceUnavailable"
    case .categoryChange: return "categoryChange"
    case .override: return "override"
    case .wakeFromSleep: return "wakeFromSleep"
    case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
    case .routeConfigurationChange: return "routeConfigurationChange"
    @unknown default: return "other(\(reason.rawValue))"
    }
  }

  private func checkBluetoothRoute() {
    let route = AVAudioSession.sharedInstance().currentRoute
    let hasBluetoothInput = route.inputs.contains { input in
      input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP
    }
    let hasBluetoothOutput = route.outputs.contains { output in
      output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP
    }
    isBluetoothConnected = hasBluetoothInput || hasBluetoothOutput
  }


}
