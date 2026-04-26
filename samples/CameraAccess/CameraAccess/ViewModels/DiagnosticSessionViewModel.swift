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

    await startGeminiLiveSession()
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
      // Synthetic follow-up so Gemini knows the manual is ready.
      try? await geminiService?.sendClientTextTurn(
        "Manual uploaded. manual_id=\(upload.manualId). Proceed with generate_sop_from_manual using this manual_id."
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
      if let p = result["product"] as? [String: Any] {
        let prod = IdentifiedProduct(
          productName: (p["product_name"] as? String) ?? "",
          category: p["category"] as? String,
          confidence: (p["confidence"] as? String) ?? "medium"
        )
        identifiedProduct = prod
        phase = .diagnosing
      }

    case "search_procedures":
      if let arr = result["candidates"] as? [[String: Any]] {
        candidateProcedures = arr.compactMap { CandidateProcedure(fromJSON: $0) }
        phase = .resolving
        if let top = candidateProcedures.first {
          resolution = .matchedProcedure(top)
        }
      } else {
        candidateProcedures = []
      }

    case "fetch_manual":
      if let status = result["status"] as? String {
        if status == "user_upload_required" {
          showManualUploadSheet = true
        } else if status == "preloaded", let procedureId = result["procedure_id"] as? String {
          let title = (result["title"] as? String) ?? "Pre-loaded procedure"
          resolution = .generatedSOP(procedureId: procedureId, title: title)
          phase = .resolving
        }
      }

    case "generate_sop_from_manual":
      if let procedureId = result["procedure_id"] as? String,
         (result["status"] as? String) == "ok" {
        resolution = .generatedSOP(procedureId: procedureId, title: "AI-generated procedure")
        phase = .resolving
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
