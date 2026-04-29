import Foundation

// MARK: - Diagnostic session lifecycle

struct DiagnosticSessionStartResponse: Codable {
  let sessionId: String
  let systemPrompt: String
  let tools: [GeminiToolDefinitionResponse]
  let geminiConfig: GeminiConfigResponse
  let ephemeralToken: EphemeralTokenResponse

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case systemPrompt = "system_prompt"
    case tools
    case geminiConfig = "gemini_config"
    case ephemeralToken = "ephemeral_token"
  }
}

struct IdentifiedProduct: Codable, Equatable {
  let productName: String
  let category: String?
  let confidence: String

  enum CodingKeys: String, CodingKey {
    case productName = "product_name"
    case category
    case confidence
  }
}

struct CandidateProcedure: Codable, Equatable, Identifiable {
  var id: String { procedureId }
  let procedureId: String
  let title: String
  let matchReason: String?
  let confidence: String?

  enum CodingKeys: String, CodingKey {
    case procedureId = "procedure_id"
    case title
    case matchReason = "match_reason"
    case confidence
  }
}

enum DiagnosticPhase: String, Codable {
  case discovering
  case diagnosing
  case resolving
  case resolved
}

struct TroubleshootSessionState: Codable {
  let sessionId: String
  let phase: String
  let status: String
  let startedAt: String
  let identifiedProduct: IdentifiedProduct?
  let candidateProcedures: [CandidateProcedure]
  let generatedProcedureId: String?
  let handoffTarget: String?
  let handoffLearnerSessionId: String?
  let webSearchProgress: WebSearchProgress?

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case phase
    case status
    case startedAt = "started_at"
    case identifiedProduct = "identified_product"
    case candidateProcedures = "candidate_procedures"
    case generatedProcedureId = "generated_procedure_id"
    case handoffTarget = "handoff_target"
    case handoffLearnerSessionId = "handoff_learner_session_id"
    case webSearchProgress = "web_search_progress"
  }
}

/// Mirrors `services.troubleshoot.session.update_web_search_progress`.
/// Phase strings: "searching_web" → "synthesizing" → terminal
/// ("complete" | "no_fix_found" | "error"). Server returns `null` outside
/// of an in-flight `web_search_for_fix` call.
struct WebSearchProgress: Codable, Equatable {
  let phase: String
  let sourceCount: Int?
  let procedureId: String?
  let errorMessage: String?
  let startedAt: String
  let updatedAt: String

  enum CodingKeys: String, CodingKey {
    case phase
    case sourceCount = "source_count"
    case procedureId = "procedure_id"
    case errorMessage = "error_message"
    case startedAt = "started_at"
    case updatedAt = "updated_at"
  }
}

// MARK: - Manual upload

struct ManualUploadResponse: Codable {
  let manualId: String
  let status: String
  let filename: String

  enum CodingKeys: String, CodingKey {
    case manualId = "manual_id"
    case status
    case filename
  }
}

struct ManualStatusResponse: Codable {
  let manualId: String
  let status: String
  let procedureId: String?
  let error: String?
  let filename: String

  enum CodingKeys: String, CodingKey {
    case manualId = "manual_id"
    case status
    case procedureId = "procedure_id"
    case error
    case filename
  }
}

// MARK: - Resolution state the view renders

enum DiagnosticResolution: Equatable {
  /// Gemini picked a procedure from search results. User confirmation
  /// triggers handoff to Learner Mode.
  case matchedProcedure(CandidateProcedure)
  /// A fresh SOP was generated from an ingested PDF. User confirmation
  /// saves (already saved server-side) and launches Learner Mode.
  case generatedSOP(procedureId: String, title: String)
  /// Search + manual both failed.
  case noMatch
}
