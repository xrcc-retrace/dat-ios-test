import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Mic input currently routing into the recording. Surfaced on the HUD as a
/// reassurance chip so the expert always knows which microphone is hot.
enum ExpertHUDMicSource: Equatable {
  case iPhoneBuiltIn
  case airPods
  case bluetoothOther
  case wiredHeadset
  case other(String)

  var label: String {
    switch self {
    case .iPhoneBuiltIn: return "iPhone mic"
    case .airPods: return "AirPods"
    case .bluetoothOther: return "BT mic"
    case .wiredHeadset: return "Wired mic"
    case .other(let name): return name
    }
  }

  var iconName: String {
    switch self {
    case .iPhoneBuiltIn: return "iphone.gen3.radiowaves.left.and.right"
    case .airPods: return "airpods"
    case .bluetoothOther: return "dot.radiowaves.left.and.right"
    case .wiredHeadset: return "headphones"
    case .other: return "mic"
    }
  }
}

/// State layer behind the Expert HUD. Owned by `IPhoneExpertRecordingViewModel`
/// (so the HUD and the recording share one lifecycle) and observed by
/// `ExpertRayBanHUD`.
///
/// Responsibilities:
///   • Pump `AudioSessionManager.lastBufferPeak` through a smoothing filter
///     so the 3-bar meter doesn't strobe.
///   • Rotate the narration tip card on a timer; respond to manual swipes.
///   • Listen for `AVAudioSession.routeChangeNotification` and recompute
///     the mic-source badge.
///   • Hold the rolling transcript pulled from `SpeechTranscriber`.
@MainActor
final class ExpertRecordingHUDViewModel: ObservableObject {
  // MARK: - Tip card rotation

  @Published private(set) var tipIndex: Int = 0

  var currentTip: ExpertNarrationTip {
    ExpertCoachingTips.pool[tipIndex % ExpertCoachingTips.pool.count]
  }

  // MARK: - Audio meter

  /// Smoothed peak in 0...1. Driven from `AudioSessionManager.lastBufferPeak`
  /// via a short-window exponential moving average so the 3-bar meter stays
  /// readable at 10 Hz without strobing.
  @Published private(set) var smoothedAudioPeak: Float = 0

  // MARK: - Mic source

  @Published private(set) var micSource: ExpertHUDMicSource = .iPhoneBuiltIn

  // MARK: - Transcript

  @Published private(set) var transcript: [String] = []

  /// Surfaces whether the speech recognizer is actually available. When
  /// false the HUD should hide the transcript card entirely.
  @Published private(set) var transcriptAvailable: Bool = false

  // MARK: - Hand tracking

  /// Latest MediaPipe landmark frame. Drives the on-HUD landmark overlay.
  /// Nil while the camera is off or no hand has been detected yet. Mirrors
  /// `GeminiLiveSessionBase.latestHandFrame` for the Learner HUD.
  @Published private(set) var latestHandFrame: HandLandmarkFrame?

  /// Rolling log of recent pinch-drag emissions. Drives `MicroGestureDebugLog`.
  @Published private(set) var recentPinchDragEvents: [PinchDragLogEntry] = []

  /// Private recognizer — one instance per camera session. Reset on
  /// `resetHandTracking()` so no stale TRACKING state survives a teardown.
  private var pinchDragRecognizer = PinchDragRecognizer()

  private let pinchDragLogMaxHistory: Int = 50

  /// Wall-clock timestamp of the most recent `[Orient]` console log.
  /// Used to throttle orientation logging to ~1 line / second while
  /// calibrating the upcoming pose-gate.
  private var lastOrientationLogAt: Date?

  // Threshold passthroughs for the debug overlay (match Learner HUD exactly).
  var indexPinchContactThreshold: Float {
    PinchDragRecognizer.Config().indexContactThreshold
  }
  var gatePalmFacingZMin: Float {
    PinchDragRecognizer.Config().gatePalmFacingZMin
  }
  var gatePalmFacingZMax: Float {
    PinchDragRecognizer.Config().gatePalmFacingZMax
  }
  var gateHandSizeMin: Float {
    PinchDragRecognizer.Config().gateHandSizeMin
  }
  var pendingSelectActive: Bool {
    pinchDragRecognizer.debugState.pendingSelectActive
  }
  var currentHighlightQuadrant: PinchDragQuadrant? {
    pinchDragRecognizer.debugState.currentHighlightQuadrant
  }
  var lastContactStartPosition: CGPoint? {
    pinchDragRecognizer.lastContactStartPosition
  }
  var lastContactReleasePosition: CGPoint? {
    pinchDragRecognizer.lastContactReleasePosition
  }

  // MARK: - Wiring

  private weak var audioSessionManager: AudioSessionManager?
  private weak var speechTranscriber: SpeechTranscriber?

  private var rotationTask: Task<Void, Never>?
  private var audioCancellable: AnyCancellable?
  private var transcriptCancellable: AnyCancellable?
  private var transcriptAvailableCancellable: AnyCancellable?
  private var routeObserver: NSObjectProtocol?

  init() {
    observeRouteChanges()
    recomputeMicSource()
  }

  deinit {
    rotationTask?.cancel()
    if let routeObserver {
      NotificationCenter.default.removeObserver(routeObserver)
    }
  }

  /// Must be called once after the owning VM has constructed its
  /// `AudioSessionManager` and `SpeechTranscriber`. Wires publishers so the
  /// HUD reacts to mic peaks + transcript deltas.
  func bind(
    audioSessionManager: AudioSessionManager,
    speechTranscriber: SpeechTranscriber
  ) {
    self.audioSessionManager = audioSessionManager
    self.speechTranscriber = speechTranscriber

    audioCancellable = audioSessionManager.$lastBufferPeak
      .receive(on: RunLoop.main)
      .sink { [weak self] newPeak in
        self?.ingestPeak(newPeak)
      }

    transcriptCancellable = speechTranscriber.$segments
      .receive(on: RunLoop.main)
      .sink { [weak self] segments in
        self?.transcript = segments
      }

    transcriptAvailableCancellable = speechTranscriber.$isAvailable
      .receive(on: RunLoop.main)
      .sink { [weak self] available in
        self?.transcriptAvailable = available
      }

    recomputeMicSource()
  }

  // MARK: - Tip rotation

  /// Start the 12 s auto-advance loop. Safe to call repeatedly.
  func startTipRotation() {
    rotationTask?.cancel()
    rotationTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(
          nanoseconds: UInt64(ExpertCoachingTips.autoAdvanceInterval * 1_000_000_000)
        )
        guard !Task.isCancelled else { return }
        await self?.advanceTip()
      }
    }
  }

  func stopTipRotation() {
    rotationTask?.cancel()
    rotationTask = nil
  }

  /// Advance to the next tip, wrapping. Resets the rotation timer so a manual
  /// swipe doesn't immediately get overridden by the auto-advance firing.
  func advanceTip() {
    tipIndex = (tipIndex + 1) % ExpertCoachingTips.pool.count
    restartRotationIfActive()
  }

  /// Go back one tip, wrapping.
  func retreatTip() {
    tipIndex = (tipIndex - 1 + ExpertCoachingTips.pool.count) % ExpertCoachingTips.pool.count
    restartRotationIfActive()
  }

  private func restartRotationIfActive() {
    guard rotationTask != nil else { return }
    startTipRotation()
  }

  // MARK: - Hand tracking ingestion

  /// Consume a MediaPipe landmark frame. Publishes it for the debug
  /// overlay and feeds `PinchDragRecognizer`; logs every classified event
  /// and maps pinch-left / pinch-right to tip cycling so the expert can
  /// flip through narration reminders without touching the phone.
  /// Called on MainActor by `IPhoneExpertRecordingViewModel` after the
  /// MediaPipe delivery queue has handed us a frame.
  func ingestHandFrame(_ frame: HandLandmarkFrame) {
    latestHandFrame = frame

    // Orientation log — throttled to ~1 line / sec so the console stays
    // readable. Gives the user ground-truth numbers to paste when
    // tuning the pose-gate range. Mirrored in GeminiLiveSessionBase for
    // the Learner path.
    if let orient = frame.orientation {
      let now = Date()
      if lastOrientationLogAt == nil ||
         now.timeIntervalSince(lastOrientationLogAt!) >= 1.0 {
        lastOrientationLogAt = now
        print(String(
          format: "[Orient] palmAngle=%+7.1f°  palmFacingZ=%+.3f  handSize=%.3f  handedness=%@",
          orient.palmAngleDegrees,
          orient.palmFacingZ,
          orient.handSize,
          frame.handedness ?? "?"
        ))
      }
    }

    guard let event = pinchDragRecognizer.ingest(frame) else { return }

    recentPinchDragEvents.append(PinchDragLogEntry(event: event))
    let overflow = recentPinchDragEvents.count - pinchDragLogMaxHistory
    if overflow > 0 {
      recentPinchDragEvents.removeFirst(overflow)
    }

    // Natural mapping — pinch-right advances the tip carousel (same
    // direction as a physical right-swipe); pinch-left retreats. Every
    // other event (including highlights, select, cancel, and back) stays
    // in the log without firing any action; we deliberately don't wire
    // destructive actions to gestures (e.g. .back → stop recording
    // would be too easy to trigger accidentally — the hold-to-confirm
    // pill exists for that specifically).
    switch event {
    case .right: advanceTip()
    case .left: retreatTip()
    case .select, .cancel, .up, .down, .back,
         .highlightLeft, .highlightRight, .highlightUp, .highlightDown:
      break
    }
  }

  /// Reset the recognizer + clear the landmark state. Call from the owning
  /// VM when a new camera session is being brought up (or torn down), so
  /// stale TRACKING state from a prior run can't carry over.
  func resetHandTracking() {
    pinchDragRecognizer = PinchDragRecognizer()
    latestHandFrame = nil
    recentPinchDragEvents.removeAll()
    lastOrientationLogAt = nil
  }

  // MARK: - Audio peak smoothing

  private func ingestPeak(_ newPeak: Float) {
    // Short EMA — fast attack, slower release. Looks like a real VU meter.
    let attack: Float = 0.65
    let release: Float = 0.22
    let alpha = newPeak > smoothedAudioPeak ? attack : release
    smoothedAudioPeak = smoothedAudioPeak + alpha * (newPeak - smoothedAudioPeak)
  }

  // MARK: - Mic source detection

  private func observeRouteChanges() {
    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor in
        self?.recomputeMicSource()
      }
    }
  }

  private func recomputeMicSource() {
    let route = AVAudioSession.sharedInstance().currentRoute
    guard let input = route.inputs.first else {
      micSource = .iPhoneBuiltIn
      return
    }
    micSource = Self.classify(input: input)
  }

  private static func classify(input: AVAudioSessionPortDescription) -> ExpertHUDMicSource {
    switch input.portType {
    case .builtInMic: return .iPhoneBuiltIn
    case .headsetMic, .headphones: return .wiredHeadset
    case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
      let lowered = input.portName.lowercased()
      if lowered.contains("airpod") { return .airPods }
      return .bluetoothOther
    default: return .other(input.portName)
    }
  }
}

// Marker conformance — all `HandGestureDebugProvider` requirements are
// already implemented above. Lets `HandGestureDebugStack` drive off the
// Expert HUD VM just like the session-base-backed Coaching and
// Troubleshoot VMs.
extension ExpertRecordingHUDViewModel: HandGestureDebugProvider {}
