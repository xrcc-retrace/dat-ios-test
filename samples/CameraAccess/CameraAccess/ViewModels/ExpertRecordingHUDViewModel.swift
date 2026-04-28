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
  //
  // Recognizer + frame log + debug-provider plumbing all live on
  // `HandGestureService.shared` now. We just route MediaPipe results
  // into it via `ingestHandFrame(_:)` (called by
  // `IPhoneExpertRecordingViewModel` from its `HandLandmarkerService.onResult`).
  //
  // Tip cycling on pinch-drag left/right used to live here on the
  // service's `onEvent` hook. It moved into the focus engine — see
  // `ExpertTipPageHandler` (installed by `ExpertNarrationTipPage` via
  // `.hudInputHandler`). The handler responds to `.directional(.left)`
  // / `.directional(.right)` (which the translator generates from
  // pinch-drag highlights) and calls `advanceTip()` / `retreatTip()`
  // directly. Keeping the legacy hook in parallel would double-fire
  // (highlight on quadrant entry → handler; terminal on release →
  // legacy hook) for the same physical gesture.

  // MARK: - Wiring

  private weak var audioSessionManager: AudioSessionManager?
  private weak var speechTranscriber: SpeechTranscriber?

  private var audioCancellable: AnyCancellable?
  private var transcriptCancellable: AnyCancellable?
  private var transcriptAvailableCancellable: AnyCancellable?
  private var routeObserver: NSObjectProtocol?

  init() {
    observeRouteChanges()
    recomputeMicSource()
  }

  deinit {
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

  // MARK: - Tip cycling

  /// Advance to the next tip, wrapping. Driven by user gesture only —
  /// no auto-rotation timer.
  func advanceTip() {
    tipIndex = (tipIndex + 1) % ExpertCoachingTips.pool.count
  }

  /// Go back one tip, wrapping.
  func retreatTip() {
    tipIndex = (tipIndex - 1 + ExpertCoachingTips.pool.count) % ExpertCoachingTips.pool.count
  }

  // MARK: - Hand tracking ingestion

  /// Routes a MediaPipe frame into the shared gesture pipeline. The
  /// service handles `latestHandFrame`, the orientation log, recognizer
  /// FSM, and event log uniformly across modes. Tip cycling is wired
  /// in `ExpertTipPageHandler` via the focus engine — no service-level
  /// `onEvent` hook is set from this VM.
  /// Called on MainActor by `IPhoneExpertRecordingViewModel` after the
  /// MediaPipe delivery queue has handed us a frame.
  func ingestHandFrame(_ frame: HandLandmarkFrame) {
    HandGestureService.shared.ingest(frame)
  }

  /// Reset the shared gesture service. Called from the owning VM when
  /// a new camera session is being brought up (or torn down), so stale
  /// recognizer state from a prior run can't carry over. Also clears
  /// any `onEvent` closure another mode may have left behind.
  func resetHandTracking() {
    HandGestureService.shared.reset()
    HandGestureService.shared.onEvent = nil
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
// `HandGestureDebugProvider` conformance now lives on `HandGestureService`,
// not the VM. Views pass `HandGestureService.shared` as the provider.
// See `HandTracking/HandGestureService.swift`.
