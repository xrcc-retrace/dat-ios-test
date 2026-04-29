import Combine
import Foundation
import MWDATCore
import SwiftUI

/// Troubleshoot-mode (diagnostic) session. Inherits the shared Gemini Live
/// machinery from `GeminiLiveSessionBase` and plugs in diagnostic-specific
/// behavior via template-method overrides.
///
/// Mode-specific state: phase machine, identified product, candidate
/// procedures, resolution, handoff orchestration, manual-upload sheet.
/// Everything else — audio, camera, WebSocket, tool-call forwarding,
/// transcripts, barge-in, resumption — lives on the base.
@MainActor
class DiagnosticSessionViewModel: GeminiLiveSessionBase {

  // MARK: - Mode-specific published state

  @Published var phase: DiagnosticPhase = .discovering
  @Published var identifiedProduct: IdentifiedProduct?
  @Published var candidateProcedures: [CandidateProcedure] = []
  @Published var resolution: DiagnosticResolution?
  @Published var showManualUploadSheet = false
  @Published var handoffInFlight = false
  @Published var handoffError: String?

  /// True after `identify_product` returns and before the user has
  /// confirmed (or rejected) it. Drives the lens confirmation overlay.
  /// Cleared when `confirm_identification` returns or when the user
  /// rejects via `requestReIdentify()` (which wipes `identifiedProduct`).
  @Published private(set) var pendingConfirmation: Bool = false

  /// Which stage of the search-for-fix flow is currently in flight.
  /// Derived from `pendingToolCallNames` on the base — `search_procedures`
  /// in flight = `.searchingLibrary`; `web_search_for_fix` in flight =
  /// `.searchingWeb`. Subscribed below in init.
  @Published private(set) var searchStage: SearchStage? = nil

  enum SearchStage: Equatable {
    case searchingLibrary
    case searchingWeb
  }

  /// Three-stage narration that drives the lens search-status surface.
  /// Distinct from `searchStage` because we synthesize an explicit
  /// `.libraryMissed` moment between DB miss and web search starting,
  /// held for 3 seconds even if `web_search_for_fix` fires (or returns)
  /// instantly. Deliberate pacing — gives the user a beat to register
  /// the library miss before being whisked into the next phase.
  @Published private(set) var searchNarration: SearchNarration? = nil

  enum SearchNarration: Equatable {
    case searchingLibrary
    case libraryMissed
    case searchingWeb
    /// Step 1 (grounded search) finished; step 2 synthesis is running.
    /// Carries the server-reported source count so the surface can read
    /// "Found N sources …".
    case synthesizing(sourceCount: Int)
    /// Server-side `complete` — procedure persisted, just before the
    /// resolution panel takes over. Held briefly (~1.0s, controlled by
    /// the tool-result handler) so the user registers the success.
    case foundFix(sourceCount: Int)
  }

  /// Owns the 3-second `.libraryMissed` hold. While non-nil, the
  /// `pendingToolCallNames` sink ignores narration changes and the
  /// `web_search_for_fix` result handler buffers its resolution into
  /// `pendingResolution` instead of applying it.
  private var libraryMissHoldTask: Task<Void, Never>?

  /// Resolution buffered while the `.libraryMissed` hold is active.
  /// Applied by the hold task after the 3-second floor elapses so the
  /// user always sees the miss line for the full duration even when
  /// `web_search_for_fix` returns in <3s.
  private var pendingResolution: DiagnosticResolution?

  /// Hard-floor for the `.libraryMissed` moment. 2.0s — long enough
  /// to read "No procedure found in your library." comfortably,
  /// short enough not to feel stalled.
  private static let libraryMissedHoldSeconds: UInt64 = 2_000_000_000

  /// Background poll of `/api/troubleshoot/session/{id}/state`, alive
  /// only while `web_search_for_fix` is in flight. Drives the
  /// `.synthesizing` and `.foundFix` narration substages.
  private var webSearchPollTask: Task<Void, Never>?

  /// Forward-only ratchet so a late poll can't rewind the surface.
  /// `searching_web < synthesizing < {complete | no_fix_found | error}`.
  private var lastPolledPhase: String?

  /// Source count from the most recent successful poll. Cached so the
  /// libraryMissed drain step can chain through `.foundFix` with the
  /// correct count even when the result handler hasn't fired yet.
  private var lastPolledSourceCount: Int?

  /// Hard-floor on the `.foundFix` success flash. Started when web
  /// search reaches the `complete` phase (whichever signal arrives
  /// first — poll or tool result) and buffers the resolution until the
  /// floor elapses, mirroring the `libraryMissHoldTask` pattern.
  private var foundFixHoldTask: Task<Void, Never>?
  private static let foundFixHoldSeconds: UInt64 = 2_500_000_000

  /// 800 ms — web search runs ~10-20s with two natural transitions, so
  /// this gives ≤1.5s lag at each boundary while keeping load light.
  private static let webSearchPollIntervalNanos: UInt64 = 800_000_000

  /// Transport chosen on the Troubleshoot intro picker. iPhone routes
  /// through the camera-first drawer layout; glasses keeps the current
  /// stacked layout.
  private let diagnosticTransport: CaptureTransport

  /// Set to true once the first mintSession succeeds so the view can read
  /// the session id if needed.
  var currentSessionId: String? { sessionId }

  // MARK: - Init

  init(
    wearables: WearablesInterface,
    serverBaseURL: String,
    transport: CaptureTransport
  ) {
    self.diagnosticTransport = transport
    super.init(wearables: wearables, serverBaseURL: serverBaseURL)

    // Derive `searchStage` and `searchNarration` from the base's
    // published map of in-flight tool names. Updates in real time as
    // the AI fires search_procedures and web_search_for_fix.
    //
    // `searchStage` is the raw mirror (kept for any consumer that
    // wants the unfiltered signal). `searchNarration` is the user-
    // facing surface and respects the synthetic `.libraryMissed` hold:
    // while the 3s hold is active we don't override narration here —
    // the hold task owns the next transition.
    $pendingToolCallNames
      .receive(on: DispatchQueue.main)
      .sink { [weak self] names in
        guard let self = self else { return }
        let activeNames = Set(names.values)

        if activeNames.contains("web_search_for_fix") {
          self.searchStage = .searchingWeb
        } else if activeNames.contains("search_procedures") {
          self.searchStage = .searchingLibrary
        } else {
          self.searchStage = nil
        }

        // Narration. A fresh search_procedures call (e.g. retry after a
        // manual upload) cancels any in-flight libraryMissed hold and
        // rewinds the surface. We also clear any stale `resolution`
        // here — if a previous search ended with a resolution that the
        // user has since rejected and the AI re-issues search_procedures,
        // the resolved/no-solution page would otherwise stay mounted
        // while the new search ran invisibly.
        if activeNames.contains("search_procedures") {
          self.libraryMissHoldTask?.cancel()
          self.libraryMissHoldTask = nil
          self.foundFixHoldTask?.cancel()
          self.foundFixHoldTask = nil
          self.cancelWebSearchProgressPolling()
          self.pendingResolution = nil
          self.resolution = nil
          self.searchNarration = .searchingLibrary
        } else if activeNames.contains("web_search_for_fix") {
          // Hold owns the transition out of .libraryMissed; ignore web
          // start while the hold is active.
          if self.libraryMissHoldTask == nil {
            // Clear any stale resolution (e.g. from a prior .noMatch the
            // user is voice-retrying). Without this, the no-solution /
            // resolved panel stays mounted while the new web call runs
            // invisibly behind it. Gated on the hold being inactive
            // because during the hold, resolution is already nil and the
            // post-hold pendingResolution flow owns the transition.
            self.resolution = nil
            self.searchNarration = .searchingWeb
          }
          // Start polling regardless of the hold — the apply step
          // self-suppresses while the hold is active and applies the
          // latest phase once the floor elapses.
          self.startWebSearchProgressPolling()
        } else {
          // Tool calls drained. If web search was active, stop polling.
          self.cancelWebSearchProgressPolling()
        }
      }
      .store(in: &cancellables)
  }

  // MARK: - Lifecycle (public entry / exit)

  func startSession() async {
    // Reset mode-specific state. Base fields (isMuted, isGeminiReady, etc.)
    // are reset inside startGeminiLiveSession → stopGeminiLiveSession paths.
    phase = .discovering
    identifiedProduct = nil
    candidateProcedures = []
    resolution = nil
    showManualUploadSheet = false
    handoffInFlight = false
    handoffError = nil
    pendingConfirmation = false
    searchStage = nil
    searchNarration = nil
    libraryMissHoldTask?.cancel()
    libraryMissHoldTask = nil
    foundFixHoldTask?.cancel()
    foundFixHoldTask = nil
    pendingResolution = nil
    cancelWebSearchProgressPolling()

    await startGeminiLiveSession()
  }

  // MARK: - Confirmation overlay actions (called from TroubleshootConfirmOverlay)

  /// User tapped "That's it" — confirm the identification. Nudges Gemini
  /// with an affirmative text turn so the AI fires `confirm_identification`,
  /// which the server uses to advance phase. Server enforces the gate; this
  /// method is just the conversational push.
  func confirmIdentification() {
    Task { try? await geminiService?.sendClientTextTurn("Yes, that's it.") }
  }

  /// User tapped "Try again" — reject the identification. Wipes the local
  /// product so the overlay dismisses, then nudges Gemini to call
  /// `identify_product` again with a different guess.
  func requestReIdentify() {
    identifiedProduct = nil
    pendingConfirmation = false
    Task {
      try? await geminiService?.sendClientTextTurn(
        "That's not the right tool. Try a different identification."
      )
    }
  }

  /// User tapped "Rediagnose" on TroubleshootResolvedPage or
  /// TroubleshootNoSolutionPage — wipe the resolution and re-enter the
  /// diagnose phase. Keeps `identifiedProduct` because the product is
  /// still the same; only the diagnostic angle (or the offered fix)
  /// was wrong. Conversational nudge biases Gemini toward asking new
  /// symptom questions before re-firing search_procedures /
  /// web_search_for_fix.
  func rediagnose() {
    resolution = nil
    candidateProcedures = []
    pendingResolution = nil
    searchNarration = nil
    libraryMissHoldTask?.cancel()
    libraryMissHoldTask = nil
    foundFixHoldTask?.cancel()
    foundFixHoldTask = nil
    cancelWebSearchProgressPolling()
    pendingConfirmation = false
    phase = .diagnosing
    Task {
      try? await geminiService?.sendClientTextTurn(
        "Let's diagnose this again — that wasn't the right angle. Ask me different symptom questions so we can try the search with new info."
      )
    }
  }

  func endSession() {
    let sid = sessionId
    if let sid {
      // Best-effort DELETE — same pattern as learner. @MainActor so
      // ProcedureAPIService construction is safe.
      Task { @MainActor in
        let apiService = ProcedureAPIService()
        await apiService.endDiagnosticSession(sessionId: sid)
      }
    }
    libraryMissHoldTask?.cancel()
    libraryMissHoldTask = nil
    foundFixHoldTask?.cancel()
    foundFixHoldTask = nil
    pendingResolution = nil
    cancelWebSearchProgressPolling()
    stopCameraStream()
    stopGeminiLiveSession()
  }

  // MARK: - Handoff to Learner

  /// Called when the user confirms a matched/generated procedure.
  /// Returns the learner session payload so the view can transition into
  /// CoachingSessionView via fullScreenCover.
  func executeHandoff(procedureId: String, autoAdvance: Bool) async -> LearnerSessionStartResponse? {
    guard let sid = sessionId else { return nil }
    handoffInFlight = true
    handoffError = nil
    let voice = VoiceSettings.storedVoice()
    do {
      let apiService = ProcedureAPIService()
      let response = try await apiService.handoffDiagnosticToLearner(
        sessionId: sid,
        procedureId: procedureId,
        autoAdvance: autoAdvance,
        voice: voice
      )
      // Learner VM will open its own fresh socket; tear down ours.
      stopCameraStream()
      stopGeminiLiveSession()
      handoffInFlight = false
      return response
    } catch {
      handoffInFlight = false
      handoffError = error.localizedDescription
      print("[Diagnostic] Handoff failed: \(error)")
      return nil
    }
  }

  // MARK: - Manual upload

  func submitManualUpload(pdfURL: URL) async -> Bool {
    let apiService = ProcedureAPIService()
    do {
      let upload = try await apiService.uploadManual(pdfURL: pdfURL)
      print("[Diagnostic] Manual uploaded: \(upload.manualId)")
      // The manual is ingested server-side and saved as a regular procedure in
      // the library. Nudge Gemini to retry search_procedures so it picks up
      // the new entry and can offer it as the resolution.
      try? await geminiService?.sendClientTextTurn(
        "I just uploaded a manual for this device. Try search_procedures again."
      )
      return true
    } catch {
      print("[Diagnostic] Manual upload failed: \(error)")
      return false
    }
  }

  // MARK: - Base overrides (template hooks)

  override func mintSession() async throws -> SessionStartPayload {
    let voice = VoiceSettings.storedVoice()
    let apiService = ProcedureAPIService()
    let response = try await apiService.startDiagnosticSession(voice: voice)
    return SessionStartPayload(
      sessionId: response.sessionId,
      ephemeralToken: response.ephemeralToken
    )
  }

  override var toolCallURLSuffix: String {
    guard let sid = sessionId else { return "/api/troubleshoot/session//tool-call" }
    return "/api/troubleshoot/session/\(sid)/tool-call"
  }

  /// Manual ingest can take 30-60s; learner's 10s default is too tight.
  override var toolCallTimeoutSeconds: TimeInterval { 90 }

  override var introSeedText: String? { "Hi, something is broken." }

  override var transport: CaptureTransport { diagnosticTransport }

  /// `.coaching` on glasses (allows HFP audio route), `.coachingPhoneOnly`
  /// on iPhone. Matches CoachingSessionViewModel's rationale — full-duplex
  /// voice + AEC regardless of transport; only the route differs.
  override var audioSessionMode: AudioSessionMode {
    diagnosticTransport == .iPhone ? .coachingPhoneOnly : .coaching
  }

  // MARK: - Library-miss hold

  /// Start the synthetic 3-second `.libraryMissed` moment. Called when
  /// `search_procedures` returns no candidates. While the hold task is
  /// alive:
  ///   - the `pendingToolCallNames` sink ignores incoming
  ///     `web_search_for_fix` so the surface doesn't flip mid-hold
  ///   - the `web_search_for_fix` result handler buffers any resolution
  ///     into `pendingResolution` instead of applying it
  ///
  /// When the 3s elapses, the task either applies the buffered
  /// resolution (web finished during the hold) or transitions narration
  /// to `.searchingWeb` (web is still in flight or hasn't started).
  // MARK: - Web search progress polling

  /// Start polling `/api/troubleshoot/session/{id}/state` while
  /// `web_search_for_fix` is in flight. Cancels any prior task. Idempotent
  /// across rapid retries — the cancel + reset of `lastPolledPhase` makes a
  /// re-fired web search start clean.
  private func startWebSearchProgressPolling() {
    webSearchPollTask?.cancel()
    lastPolledPhase = nil
    webSearchPollTask = Task { @MainActor [weak self] in
      let api = ProcedureAPIService()
      while !Task.isCancelled {
        guard let self = self, let sid = self.sessionId else { return }
        if let state = try? await api.fetchDiagnosticState(sessionId: sid),
           let progress = state.webSearchProgress {
          self.applyWebSearchProgress(progress)
        }
        try? await Task.sleep(nanoseconds: Self.webSearchPollIntervalNanos)
      }
    }
  }

  private func cancelWebSearchProgressPolling() {
    webSearchPollTask?.cancel()
    webSearchPollTask = nil
    lastPolledPhase = nil
  }

  /// Map server `web_search_progress.phase` onto `searchNarration` with a
  /// forward-only ratchet, so a slow poll arriving after the surface has
  /// already advanced can't rewind it. Suppresses while the
  /// `.libraryMissed` 3.0s floor owns the surface — the hold's drain step
  /// will re-read the current phase and surface it then.
  private func applyWebSearchProgress(_ progress: WebSearchProgress) {
    let order: [String: Int] = [
      "searching_web": 0,
      "synthesizing": 1,
      "complete": 2,
      "no_fix_found": 2,
      "error": 2,
    ]
    guard let nextRank = order[progress.phase] else { return }
    if let last = lastPolledPhase, let lastRank = order[last], nextRank < lastRank {
      return
    }
    lastPolledPhase = progress.phase

    // Cache the latest source count so the libraryMiss drain step (or any
    // other late hand-off) can render the right "Found N sources" text
    // without re-polling.
    if let count = progress.sourceCount {
      lastPolledSourceCount = count
    }

    if libraryMissHoldTask != nil { return }

    switch progress.phase {
    case "synthesizing":
      searchNarration = .synthesizing(sourceCount: progress.sourceCount ?? 0)
    case "complete":
      ensureFoundFixHold(sourceCount: progress.sourceCount ?? lastPolledSourceCount ?? 0)
    case "no_fix_found", "error":
      // Tool-result handler drives `resolution = .noMatch`; the existing
      // `TroubleshootNoSolutionPage` is the surface for both terminals.
      break
    case "searching_web":
      if searchNarration != .searchingWeb { searchNarration = .searchingWeb }
    default:
      break
    }
  }

  /// Show the `.foundFix` flash and hold for 1.5s before letting the
  /// resolution panel take over. Called by both the poll path (server
  /// phase reaches `complete`) and the tool-result path (whichever
  /// arrives first wins the start; subsequent calls refresh the count
  /// only). Buffers `pendingResolution` until the floor elapses.
  private func ensureFoundFixHold(sourceCount: Int) {
    if foundFixHoldTask != nil {
      // Already holding — refresh the count if it changed.
      searchNarration = .foundFix(sourceCount: sourceCount)
      return
    }
    searchNarration = .foundFix(sourceCount: sourceCount)
    foundFixHoldTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: Self.foundFixHoldSeconds)
      guard let self = self, !Task.isCancelled else { return }
      self.foundFixHoldTask = nil
      if let buffered = self.pendingResolution {
        self.pendingResolution = nil
        self.resolution = buffered
      }
      self.searchNarration = nil
    }
  }

  private func startLibraryMissedHold() {
    libraryMissHoldTask?.cancel()
    pendingResolution = nil
    searchNarration = .libraryMissed

    libraryMissHoldTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: Self.libraryMissedHoldSeconds)
      guard let self = self, !Task.isCancelled else { return }
      self.libraryMissHoldTask = nil

      if let buffered = self.pendingResolution {
        if case .generatedSOP = buffered {
          // Chain a successful web search through the `.foundFix` flash
          // so the user sees the success beat even when web returned
          // during the libraryMissed floor. Re-buffer; foundFix's drain
          // applies the resolution.
          let count = self.lastPolledSourceCount ?? 0
          self.ensureFoundFixHold(sourceCount: count)
        } else {
          // .noMatch — straight to the no-solution panel, no flash.
          self.pendingResolution = nil
          self.resolution = buffered
          self.searchNarration = nil
        }
      } else {
        // Web is still in flight. The poll has been ticking during the
        // hold so `lastPolledPhase` may already be ahead of
        // `searching_web`; honor it so we don't visually rewind.
        switch self.lastPolledPhase {
        case "synthesizing":
          // Source count isn't cached on the VM; the next poll tick
          // (≤800 ms away) will overwrite with the live count. Seed
          // with 0 so the surface lands immediately.
          self.searchNarration = .synthesizing(sourceCount: 0)
        case "complete":
          self.searchNarration = .foundFix(sourceCount: 0)
        default:
          self.searchNarration = .searchingWeb
        }
      }
    }
  }

  override func handleToolCallExtras(name: String, args: [String: Any], result: [String: Any]) async {
    switch name {
    case "identify_product":
      // Phase stays at .discovering. The user must explicitly confirm via
      // the lens overlay → conversational nudge → `confirm_identification`
      // tool call. Server-side gate enforced via the troubleshoot prompt.
      if let p = result["product"] as? [String: Any] {
        let prod = IdentifiedProduct(
          productName: (p["product_name"] as? String) ?? "",
          category: p["category"] as? String,
          confidence: (p["confidence"] as? String) ?? "medium"
        )
        identifiedProduct = prod
        pendingConfirmation = true
      }

    case "confirm_identification":
      // Server has advanced phase to DIAGNOSING; mirror it locally and
      // dismiss the confirmation overlay.
      pendingConfirmation = false
      phase = .diagnosing

    case "search_procedures":
      let candidates = (result["candidates"] as? [[String: Any]])?
        .compactMap { CandidateProcedure(fromJSON: $0) } ?? []
      candidateProcedures = candidates
      phase = .resolving
      if let top = candidates.first {
        resolution = .matchedProcedure(top)
        searchNarration = nil
      } else {
        // Library miss. Drop the user into the explicit
        // "No procedure found in your library." moment for a hard
        // 3-second floor — even if web_search_for_fix fires (or
        // returns) immediately, the surface stays put for the full
        // duration. Pacing > responsiveness here.
        startLibraryMissedHold()
      }

    case "web_search_for_fix":
      let pending: DiagnosticResolution? = {
        let status = (result["status"] as? String) ?? ""
        switch status {
        case "ok":
          if let procedureId = result["procedure_id"] as? String {
            let title = (result["title"] as? String) ?? "Generated procedure"
            return .generatedSOP(procedureId: procedureId, title: title)
          }
          return nil
        case "no_fix_found", "error":
          return .noMatch
        default:
          return nil
        }
      }()
      guard let pending = pending else { break }
      phase = .resolving
      let isGenerated: Bool = {
        if case .generatedSOP = pending { return true }
        return false
      }()
      let toolSourceCount = (result["sources_count"] as? Int)
        ?? lastPolledSourceCount
        ?? 0

      if libraryMissHoldTask != nil {
        // libraryMissed hold owns the surface. Buffer; its drain step
        // chains a .generatedSOP through `.foundFix` (and applies a
        // .noMatch directly).
        pendingResolution = pending
      } else if isGenerated {
        // Success — show the `.foundFix` flash for at least 1.5s
        // before letting the resolution panel arrive. ensureFoundFixHold
        // is idempotent: if the poll already started the hold, this
        // just refreshes the count.
        pendingResolution = pending
        ensureFoundFixHold(sourceCount: toolSourceCount)
      } else {
        // .noMatch (no_fix_found / error). Cancel any stale foundFix
        // hold (rare — would mean we got `complete` from poll then
        // an error from the tool) and apply directly.
        foundFixHoldTask?.cancel()
        foundFixHoldTask = nil
        resolution = pending
        searchNarration = nil
      }

    case "handoff_to_learner":
      if let procedureId = result["procedure_id"] as? String,
         let candidate = candidateProcedures.first(where: { $0.procedureId == procedureId }) {
        resolution = .matchedProcedure(candidate)
      }
      phase = .resolved
      // The atomic teardown + learner socket open happens in executeHandoff(),
      // triggered by the view's "Start Procedure" CTA. The tool call itself
      // is just a signal.

    default:
      break
    }
  }
}

// MARK: - JSON helper

private extension CandidateProcedure {
  init?(fromJSON dict: [String: Any]) {
    guard let id = dict["procedure_id"] as? String,
          let title = dict["title"] as? String else { return nil }
    self.procedureId = id
    self.title = title
    self.matchReason = dict["match_reason"] as? String
    self.confidence = dict["confidence"] as? String
  }
}
