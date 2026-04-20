import AVFoundation
import Foundation
import Speech

/// Thin `SFSpeechRecognizer` wrapper that streams audio buffers from the
/// same mic tap `ExpertRecordingManager` uses, and publishes a rolling list
/// of recognised segments for the Expert HUD to render.
///
/// Design notes:
///   • On-device recognition is preferred (iOS 17+). Falls back to
///     server-based recognition if the locale can't run on-device.
///   • `SFSpeechAudioBufferRecognitionRequest` has an internal ~1-minute
///     cap — when the current request terminates, we silently open a fresh
///     one and keep appending, so the rolling transcript never visibly
///     stalls.
///   • `isAvailable` stays `false` when the user denies permission or the
///     device reports no recognizer for the locale; the HUD then hides the
///     transcript card without breaking the rest of the layout.
///   • Primary consumer of `AudioSessionManager.onAudioBuffer` stays the
///     writer. This transcriber is installed as a secondary consumer so
///     its failure mode can never starve the recording.
@MainActor
final class SpeechTranscriber: ObservableObject {
  /// `true` once authorization + recognizer availability are confirmed.
  /// When `false`, the HUD should hide the transcript card.
  @Published private(set) var isAvailable = false

  /// Rolling list of finalized / in-flight transcription fragments. The
  /// most-recent fragment is last. Capped to the last `maxSegments` entries.
  @Published private(set) var segments: [String] = []

  private let maxSegments: Int
  private let recognizer: SFSpeechRecognizer?

  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  /// The most recent partial transcription for the in-flight request.
  /// Replaced on every partial update; promoted to `segments` when the
  /// request finalizes or rolls over.
  private var inflightPartial: String = ""
  /// Set when `stop()` is called, so a late `didFinish` callback from the
  /// recognizer doesn't auto-roll the request and reopen the mic.
  private var stopped = false
  private var authRequested = false

  init(locale: Locale = .current, maxSegments: Int = 3) {
    self.maxSegments = maxSegments
    self.recognizer = SFSpeechRecognizer(locale: locale)
      ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  }

  deinit {
    task?.cancel()
  }

  // MARK: - Lifecycle

  /// Request authorization if needed and open a streaming recognition task.
  /// Safe to call repeatedly — becomes a no-op if already recognising.
  func start() async {
    if stopped {
      stopped = false
      segments = []
      inflightPartial = ""
    }

    let granted = await Self.requestAuthorization()
    authRequested = true
    guard granted, let recognizer, recognizer.isAvailable else {
      isAvailable = false
      return
    }

    isAvailable = true
    openRequest(using: recognizer)
  }

  /// Push a mic buffer into the current recognition request. No-op when
  /// the transcriber is stopped, unauthorized, or in between requests.
  nonisolated func append(_ buffer: AVAudioPCMBuffer) {
    Task { @MainActor [weak self] in
      self?.request?.append(buffer)
    }
  }

  /// End the current recognition task and freeze the published state.
  /// After `stop()`, late `didFinish` callbacks from the recognizer must
  /// NOT auto-roll into a new request — the caller has moved on.
  func stop() {
    stopped = true
    finalizeCurrentRequest()
  }

  // MARK: - Internals

  private func openRequest(using recognizer: SFSpeechRecognizer) {
    finalizeCurrentRequest()
    stopped = false

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }
    self.request = request
    self.inflightPartial = ""

    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.handleRecognition(result: result, error: error, recognizer: recognizer)
      }
    }
  }

  private func handleRecognition(
    result: SFSpeechRecognitionResult?,
    error: Error?,
    recognizer: SFSpeechRecognizer
  ) {
    if let result {
      let transcript = result.bestTranscription.formattedString
      inflightPartial = transcript
      publish(inflightPartial: transcript)

      if result.isFinal {
        // Request has fully resolved; promote and roll over.
        inflightPartial = ""
        self.request?.endAudio()
        self.request = nil
        task = nil
        if !stopped {
          openRequest(using: recognizer)
        }
      }
    }

    if let nsError = error as NSError? {
      // `SFSpeechErrorDomain` code 216 is the common "no speech detected"
      // / rollover case. Anything else is still recoverable — the user may
      // have connected AirPods or switched routes. Try to reopen unless
      // the caller explicitly stopped us.
      _ = nsError
      task = nil
      request = nil
      if !stopped {
        openRequest(using: recognizer)
      }
    }
  }

  private func finalizeCurrentRequest() {
    request?.endAudio()
    request = nil
    task?.cancel()
    task = nil
    if !inflightPartial.isEmpty {
      appendSegment(inflightPartial)
      inflightPartial = ""
    }
  }

  /// Merge the latest partial into `segments` as a replacement for the
  /// last fragment (if any). Keeps the rolling list capped to `maxSegments`.
  private func publish(inflightPartial transcript: String) {
    // Split on sentence-ish boundaries so the rolling card shows the most
    // recent ~3 utterances rather than one giant blob.
    let chunks = splitIntoLines(transcript)
    var merged = segments
    // Drop the last `chunks.count` existing segments — those were the
    // partial's previous state; replace them with the new chunks.
    let overlap = min(chunks.count, merged.count)
    merged.removeLast(overlap)
    merged.append(contentsOf: chunks)
    if merged.count > maxSegments {
      merged = Array(merged.suffix(maxSegments))
    }
    if merged != segments {
      segments = merged
    }
  }

  private func appendSegment(_ text: String) {
    let chunks = splitIntoLines(text)
    var merged = segments + chunks
    if merged.count > maxSegments {
      merged = Array(merged.suffix(maxSegments))
    }
    segments = merged
  }

  /// Split on sentence-final punctuation so the transcript card shows
  /// readable line-sized fragments rather than a scrolling paragraph.
  private func splitIntoLines(_ text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    var lines: [String] = []
    var current = ""
    for character in trimmed {
      current.append(character)
      if ".!?".contains(character) {
        let line = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { lines.append(line) }
        current = ""
      }
    }
    let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { lines.append(tail) }
    return lines.isEmpty ? [trimmed] : lines
  }

  // MARK: - Authorization

  private static func requestAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }
}
