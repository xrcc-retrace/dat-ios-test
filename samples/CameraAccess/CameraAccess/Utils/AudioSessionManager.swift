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
  /// Peak sample amplitude from the most recent mic buffer, in `0...1`.
  /// Fed to the Expert HUD's audio meter. Cheap to compute (one pass over
  /// the buffer in `recordCapturedBuffer`); the HUD smooths it further.
  @Published var lastBufferPeak: Float = 0

  /// EMA-smoothed peak amplitude of the AI's voice output, in `0...1`.
  /// Updated each time a Gemini Live PCM buffer is scheduled to the player
  /// node, then reset to 0 when the queue empties (the consuming meter's
  /// own rolling buffer handles the visual fade-out). Drives the audio
  /// meter in coaching + troubleshoot.
  @Published var aiOutputPeak: Float = 0

  /// EMA-smoothed peak amplitude of the user's mic input, in `0...1`.
  /// Parallel to `aiOutputPeak` — drives the "listening" state of the
  /// audio meter so the lens has a visible signal that the mic is
  /// hearing the user (white meter), distinct from the AI-speaking
  /// pastel palette. Updated from `recordCapturedBuffer` with the same
  /// asymmetric attack/release as the AI peak.
  @Published var userInputPeak: Float = 0

  /// Timestamp of the most recent audio activity in either direction —
  /// AI playback chunk enqueue OR mic input peak crossing the
  /// "user speaking" floor. Used by the coaching heartbeat as a
  /// foolproof "is anyone talking right now" gate: peak booleans flip
  /// off in inter-chunk gaps, but this timestamp only moves forward
  /// when something real happened, so a debounce window over it
  /// reliably bridges those gaps.
  @Published private(set) var lastAudioActivityAt: Date = .distantPast

  /// Mic-peak floor above which `recordCapturedBuffer` pings
  /// `lastAudioActivityAt`. Below this, room tone / AEC residue is
  /// ignored so the timestamp doesn't stay permanently fresh.
  private static let userSpeakingFloor: Float = 0.05

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

  /// True once `prewarm()` has put the audio session in its target category
  /// AND the input audio unit has been instantiated against a settled
  /// hardware format. `startCaptureAsync()` skips the off-main session
  /// reconfigure when this is set, so it doesn't queue a fresh
  /// route-change cascade right under `engine.start()` — the original
  /// -10868 race. Reset by `stopCapture()`.
  private var didPrewarm = false

  /// Called on the audio capture queue with each PCM buffer.
  var onAudioBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

  /// Optional second consumer fired AFTER `onAudioBuffer`. Lets a caller
  /// piggyback on the same mic tap as the writer/primary without risking
  /// starvation — the primary is invoked first. Install via
  /// `installSecondaryAudioConsumer`. Currently unused; left in place so
  /// future side-channel listeners (analytics, mic diagnostics, etc.) can
  /// hook in without changing the audio plumbing.
  var onAudioBufferSecondary: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

  /// Install a secondary audio consumer (see `onAudioBufferSecondary`).
  func installSecondaryAudioConsumer(
    _ consumer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
  ) {
    onAudioBufferSecondary = consumer
  }

  /// Remove the secondary audio consumer. Safe to call when none is installed.
  func removeSecondaryAudioConsumer() {
    onAudioBufferSecondary = nil
  }

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
        // No `.allowBluetoothA2DP` — A2DP is an output-only sink profile;
        // pairing it with `.record` (input-only) makes iOS reject the whole
        // setCategory call with kAudio_ParamError (-50). DAT SDK glasses
        // route their mic through BT HFP anyway; HFP is the bidirectional
        // voice profile both Ray-Bans and AirPods use for capture.
        try session.setCategory(
          .record,
          mode: .default,
          options: [.allowBluetoothHFP]
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

  /// Errors thrown out of `startCaptureAsync()`. Surfaced so the recording
  /// path can abort cleanly instead of silently producing audio-less mp4s
  /// when `engine.start()` fails (the original `-10868` symptom).
  enum AudioStartError: LocalizedError {
    case engineFailedAfterRetry(NSError)
    case invalidInputFormat

    var errorDescription: String? {
      switch self {
      case .engineFailedAfterRetry(let underlying):
        return "Audio engine failed to start (\(underlying.code))."
      case .invalidInputFormat:
        return "Audio input is not available (rate=0)."
      }
    }
  }

  // MARK: - Capture

  /// Pre-warm the audio session and input audio unit ahead of the first
  /// `startCapture` call. Called from the recording VM's `prepare()` so by
  /// the time the user can tap **Start Recording** the session is already
  /// in `.record`, the input AU is instantiated against the real hardware
  /// format, and any queued route-change notifications have drained.
  ///
  /// This eliminates the original `-10868` race: previously the FIRST
  /// access of `engine.inputNode` happened on `MainActor` BEFORE the
  /// session was switched to `.record`, so the AU cached a stale format
  /// (`.solo_ambient` rate 0 / `.playback` from a prior voice preview),
  /// then `engine.start()` validated the input chain against that stale
  /// format mid-route-change cascade and failed.
  ///
  /// Idempotent — early-out if already pre-warmed and the session is still
  /// in our target category.
  func prewarm() async {
    if didPrewarm { return }

    let capturedMode = mode

    // 1) Move the audio session into our target category off-main so the
    //    main thread keeps rendering the camera preview while
    //    setCategory + setActive + setPreferredInput run.
    await Task.detached(priority: .userInitiated) {
      Self.configureSessionOffMain(mode: capturedMode)
    }.value

    // 2) FIRST access of `engine.inputNode` — now the audio session is in
    //    `.record` (or `.playAndRecord`), so the lazily-instantiated input
    //    AU caches the real hardware format instead of a stale one.
    let node = inputNode

    // 3) Force the AU into the right voice-processing mode for this
    //    session. Recording mode pins it to plain RemoteIO so a prior
    //    coaching session can't leave a 5-channel VPIO format behind that
    //    would later fail input-chain validation.
    do {
      if capturedMode == .coaching || capturedMode == .coachingPhoneOnly {
        try node.setVoiceProcessingEnabled(true)
      } else {
        try node.setVoiceProcessingEnabled(false)
      }
    } catch {
      print("[AudioSession] prewarm: setVoiceProcessingEnabled failed: \(error)")
    }

    // 4) Drain queued route-change notifications. setCategory + setActive +
    //    setPreferredInput each post a notification; iOS delivers them
    //    asynchronously on the main run loop. Yield + sleep so they land
    //    BEFORE any subsequent engine.start sees the input chain.
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms

    didPrewarm = true
    print("[AudioSession] prewarm complete (mode=\(capturedMode))")
  }

  /// Off-main variant of `startCapture()` used by the recording path. Moves
  /// the ~200 ms of `AVAudioSession` + `AVAudioEngine` setup onto a user-
  /// initiated background task so the UI thread doesn't freeze while the
  /// user waits for "Start recording" to flip. The sync `startCapture()`
  /// above is kept for the coaching-path call sites that already run inside
  /// larger async flows.
  ///
  /// Throws `AudioStartError` on terminal failure (after one automatic
  /// retry) so the recording path can surface "Audio failed to start"
  /// instead of silently producing a silent mp4.
  func startCaptureAsync() async throws {
    guard !isCapturing else { return }

    let capturedMode = mode

    // Phase 1 — bring the audio session + input AU into the right state.
    // If `prewarm()` already ran, this is a cheap no-op; otherwise we
    // do the same work synchronously here as a fallback.
    if !didPrewarm {
      await Task.detached(priority: .userInitiated) { [inputNode = self.inputNode] in
        Self.configureSessionOffMain(mode: capturedMode)
        do {
          if capturedMode == .coaching || capturedMode == .coachingPhoneOnly {
            try inputNode.setVoiceProcessingEnabled(true)
          } else {
            try inputNode.setVoiceProcessingEnabled(false)
          }
        } catch {
          print("[AudioSession] ⚠ setVoiceProcessingEnabled failed: \(error)")
        }
      }.value
      // Same drain as in prewarm.
      try? await Task.sleep(nanoseconds: 50_000_000)
      didPrewarm = true
    }

    // Phase 2 — sanity-check the input format before installing the tap.
    // If the format is degenerate, kick the session config once and
    // re-check. Bail loudly rather than silently capturing nothing.
    if !ensureValidInputFormat() {
      // One recovery pass: re-run session config + drain.
      await Task.detached(priority: .userInitiated) {
        Self.configureSessionOffMain(mode: capturedMode)
      }.value
      try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
      if !ensureValidInputFormat() {
        throw AudioStartError.invalidInputFormat
      }
    }

    // Phase 3 — install the mic tap on main. Tap installation is a few-µs
    // op on AVAudioInputNode; doing it on main matches the existing
    // `installMicTap()` pattern.
    installMicTap()

    // Phase 4 — engine.prepare() + engine.start(), with one retry on
    // failure. `prepare()` gives the engine an explicit format-negotiation
    // pass against the now-settled input chain; without it, start() can
    // race a not-yet-finalized AU format and emit -10868.
    do {
      try await startEngineWithRetry()
    } catch {
      inputNode.removeTap(onBus: 0)
      throw error
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

  /// Validate the live input format before we commit to a tap install /
  /// engine start. A 0-rate format means the session hasn't actually
  /// engaged the input route yet — proceeding silently captures nothing.
  private func ensureValidInputFormat() -> Bool {
    let f = inputNode.inputFormat(forBus: 0)
    return f.sampleRate > 0 && f.channelCount > 0
  }

  /// Run `engine.prepare()` + `engine.start()`. On failure: reset the
  /// engine, re-run the session config, drain route-change notifications,
  /// re-install the tap, retry once. Throws `AudioStartError.engineFailedAfterRetry`
  /// if the second attempt also fails so the caller can surface a clear
  /// error instead of silently producing a silent recording.
  private func startEngineWithRetry() async throws {
    let capturedMode = mode
    let capturedEngine = engine

    let firstAttempt: NSError? = await Task.detached(priority: .userInitiated) {
      capturedEngine.prepare()
      do {
        try capturedEngine.start()
        return nil
      } catch {
        return error as NSError
      }
    }.value

    if firstAttempt == nil { return }

    print("[AudioSession] engine.start failed (\(firstAttempt!.code)), recovering and retrying")

    // Recovery: tear down everything that could be in a bad state and
    // re-run the session config to nudge iOS into re-publishing the
    // route. Then retry start once.
    inputNode.removeTap(onBus: 0)
    capturedEngine.reset()

    await Task.detached(priority: .userInitiated) { [inputNode = self.inputNode] in
      Self.configureSessionOffMain(mode: capturedMode)
      do {
        if capturedMode == .coaching || capturedMode == .coachingPhoneOnly {
          try inputNode.setVoiceProcessingEnabled(true)
        } else {
          try inputNode.setVoiceProcessingEnabled(false)
        }
      } catch {
        print("[AudioSession] retry: setVoiceProcessingEnabled failed: \(error)")
      }
    }.value

    // Generous drain — the failure mode is route-change cascade.
    try? await Task.sleep(nanoseconds: 150_000_000)  // 150 ms

    installMicTap()

    let secondAttempt: NSError? = await Task.detached(priority: .userInitiated) {
      capturedEngine.prepare()
      do {
        try capturedEngine.start()
        return nil
      } catch {
        return error as NSError
      }
    }.value

    if let err = secondAttempt {
      print("[AudioSession] engine.start failed on retry too (\(err.code))")
      throw AudioStartError.engineFailedAfterRetry(err)
    }
    print("[AudioSession] engine.start retry succeeded")
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
        // A2DP is invalid with `.record` (output-only profile); see the
        // sibling `configureAudioSession()` for the full reasoning. HFP
        // alone is what DAT SDK glasses actually route their mic through.
        try session.setCategory(
          .record,
          mode: .default,
          options: [.allowBluetoothHFP]
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
    } else {
      // Defensive: a prior coaching session in this app launch may have
      // left the input audio unit in VPIO mode (5-ch multichannel
      // format). Recording-mode `engine.start()` then fails input
      // chain validation with -10868 kAudioUnitErr_FormatNotSupported.
      // Calling false on a non-VPIO node is a no-op; on a leaked-VPIO
      // node it forces it back to standard RemoteIO so the engine
      // starts cleanly. Mirror in `startCaptureAsync`.
      do {
        try inputNode.setVoiceProcessingEnabled(false)
      } catch {
        print("[AudioSession] ⚠ Failed to disable voice processing: \(error)")
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
      // Primary (writer) first — it must never be starved by a slow secondary.
      self.onAudioBuffer?(buffer, time)
      // Optional secondary consumer (currently no installer in tree).
      self.onAudioBufferSecondary?(buffer, time)
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
    onAudioBufferSecondary = nil
    lastBufferPeak = 0
    aiOutputPeak = 0
    userInputPeak = 0
    stopStatsTimer()
    audioConverter = nil
    converterInputFormat = nil
    // Pre-warm state belongs to a single capture cycle. Reset so the next
    // recording's `prewarm()` actually re-engages the input AU instead of
    // early-returning against a category we just flipped to `.playback`.
    didPrewarm = false

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

  /// Fully release the shared `AVAudioSession`. Recording-mode `stopCapture`
  /// intentionally leaves the session active in `.playback` so the review
  /// sheet's `AVPlayer` can play the just-captured file. When the user
  /// finally backs out of the recording flow entirely, call this so other
  /// apps' background audio resumes cleanly. Idempotent.
  func deactivate() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      print("[AudioSession] Failed to deactivate: \(error)")
    }
    // Deactivating throws away the route we pre-warmed against, so the
    // next entry into the recording flow needs a fresh `prewarm()`.
    didPrewarm = false
  }

  // MARK: - Capture telemetry

  /// Called from the tap thread on every captured buffer.
  /// Extract primitives here so we don't capture the non-Sendable
  /// `AVAudioPCMBuffer` into the main-actor hop closure.
  nonisolated private func recordCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
    let peak = Self.peakAmplitude(of: buffer)
    Task { @MainActor [weak self] in
      guard let self = self else { return }
      self.lastBufferReceivedAt = Date()
      self.captureBuffersSinceLastFlush += 1
      self.silentMicWarned = false  // buffers are flowing; re-arm watchdog
      self.lastBufferPeak = peak
      // EMA shape mirrors `aiOutputPeak`: faster attack than release so a
      // sharp utterance pops the meter, then it tails off softly.
      let alpha: Float = peak > self.userInputPeak ? 0.6 : 0.2
      self.userInputPeak += alpha * (peak - self.userInputPeak)
      if self.userInputPeak >= Self.userSpeakingFloor {
        self.lastAudioActivityAt = Date()
      }
    }
  }

  /// Max absolute sample value across the buffer, normalized to 0...1.
  /// Handles the common Float32 and Int16 cases; returns 0 for unsupported
  /// formats so the UI meter just stays dark instead of misreporting.
  nonisolated private static func peakAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return 0 }
    let channelCount = Int(buffer.format.channelCount)

    if let floatPtr = buffer.floatChannelData {
      var peak: Float = 0
      for channel in 0..<channelCount {
        let samples = floatPtr[channel]
        for i in 0..<frameLength {
          let mag = abs(samples[i])
          if mag > peak { peak = mag }
        }
      }
      return min(1.0, peak)
    }

    if let int16Ptr = buffer.int16ChannelData {
      var peak: Int32 = 0
      for channel in 0..<channelCount {
        let samples = int16Ptr[channel]
        for i in 0..<frameLength {
          let mag = Int32(samples[i].magnitude)
          if mag > peak { peak = mag }
        }
      }
      return min(1.0, Float(peak) / Float(Int16.max))
    }

    return 0
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

    // Sample the buffer's amplitude here so the audio meter responds to
    // the AI's actual voice volume. Cheap one-pass scan, same primitive
    // used on the input path.
    let rawPeak = Self.peakAmplitude(of: buffer)

    scheduledBufferCount += 1
    Task { @MainActor [weak self] in
      guard let self = self else { return }
      self.isAISpeaking = true
      // Ping the activity timestamp on every chunk enqueue so
      // inter-chunk gaps in `scheduledBufferCount` can't reset the
      // "AI is talking" signal mid-utterance.
      self.lastAudioActivityAt = Date()
      // EMA: fast attack (0.6) so the meter spikes immediately when AI
      // starts a phoneme; slower release (0.2) so it doesn't strobe in
      // the silences between syllables. The consuming meter additionally
      // smooths via its own rolling buffer.
      let alpha: Float = rawPeak > self.aiOutputPeak ? 0.6 : 0.2
      self.aiOutputPeak += alpha * (rawPeak - self.aiOutputPeak)
    }

    playerNode.scheduleBuffer(buffer) { [weak self] in
      guard let self = self else { return }
      Task { @MainActor in
        self.scheduledBufferCount -= 1
        if self.scheduledBufferCount <= 0 {
          self.scheduledBufferCount = 0
          self.isAISpeaking = false
          // Hand off to the meter's roll-off — set source to 0 and the
          // meter's rolling buffer drains over ~630 ms.
          self.aiOutputPeak = 0
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
    aiOutputPeak = 0
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
