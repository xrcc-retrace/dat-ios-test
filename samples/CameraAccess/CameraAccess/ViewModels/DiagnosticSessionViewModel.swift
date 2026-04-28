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

    // Derive `searchStage` from the base's published map of in-flight tool
    // names. Updates in real time as the AI fires search_procedures and
    // web_search_for_fix.
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
      if let arr = result["candidates"] as? [[String: Any]] {
        candidateProcedures = arr.compactMap { CandidateProcedure(fromJSON: $0) }
        phase = .resolving
        if let top = candidateProcedures.first {
          resolution = .matchedProcedure(top)
        }
      } else {
        candidateProcedures = []
        phase = .resolving
      }

    case "web_search_for_fix":
      let status = (result["status"] as? String) ?? ""
      switch status {
      case "ok":
        if let procedureId = result["procedure_id"] as? String {
          let title = (result["title"] as? String) ?? "Generated procedure"
          resolution = .generatedSOP(procedureId: procedureId, title: title)
        }
        phase = .resolving
      case "no_fix_found", "error":
        resolution = .noMatch
        phase = .resolving
      default:
        break
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
