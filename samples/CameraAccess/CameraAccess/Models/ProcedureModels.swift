import Foundation

struct UploadResponse: Codable {
  let id: String
  let status: String
}

struct ProcedureResponse: Codable, Identifiable {
  let id: String
  let title: String
  let description: String
  let steps: [ProcedureStepResponse]
  let totalDuration: Double
  let createdAt: String
  let status: String?
  let errorMessage: String?

  enum CodingKeys: String, CodingKey {
    case id, title, description, steps, status
    case totalDuration = "total_duration"
    case createdAt = "created_at"
    case errorMessage = "error_message"
  }
}

struct ProcedureStepResponse: Codable, Identifiable {
  var id: Int { stepNumber }
  let stepNumber: Int
  let title: String
  let description: String
  let timestampStart: Double
  let timestampEnd: Double
  let tips: [String]
  let warnings: [String]
  let clipUrl: String?

  enum CodingKeys: String, CodingKey {
    case title, description, tips, warnings
    case stepNumber = "step_number"
    case timestampStart = "timestamp_start"
    case timestampEnd = "timestamp_end"
    case clipUrl = "clip_url"
  }
}

// MARK: - List response (lighter model from GET /api/procedures)

struct ProcedureListItem: Codable, Identifiable {
  let id: String
  let title: String
  let description: String
  let totalDuration: Double
  let createdAt: String
  let status: String?
  let errorMessage: String?
  let stepCount: Int?

  enum CodingKeys: String, CodingKey {
    case id, title, description, status
    case totalDuration = "total_duration"
    case createdAt = "created_at"
    case errorMessage = "error_message"
    case stepCount = "step_count"
  }
}

// MARK: - Edit requests

struct ProcedureUpdateRequest: Codable {
  var title: String?
  var description: String?
  var stepOrder: [Int]?

  enum CodingKeys: String, CodingKey {
    case title, description
    case stepOrder = "step_order"
  }
}

struct StepUpdateRequest: Codable {
  var title: String?
  var description: String?
  var tips: [String]?
  var warnings: [String]?
  var timestampStart: Double?
  var timestampEnd: Double?

  enum CodingKeys: String, CodingKey {
    case title, description, tips, warnings
    case timestampStart = "timestamp_start"
    case timestampEnd = "timestamp_end"
  }
}

// MARK: - Gemini Live session models

struct EphemeralTokenResponse: Codable {
  let token: String
  let expiresAt: String
  let websocketUrl: String

  enum CodingKeys: String, CodingKey {
    case token
    case expiresAt = "expires_at"
    case websocketUrl = "websocket_url"
  }
}

struct GeminiToolParam: Codable {
  let type: String
  let properties: [String: GeminiToolParamProperty]?
  let required: [String]?
}

struct GeminiToolParamProperty: Codable {
  let type: String
  let description: String?
}

struct GeminiToolDefinitionResponse: Codable {
  let name: String
  let description: String
  let parameters: GeminiToolParam
}

struct GeminiConfigResponse: Codable {
  let model: String
  let voice: String
}

struct LearnerSessionStartResponse: Codable {
  let sessionId: String
  let procedure: ProcedureResponse
  let systemPrompt: String
  let tools: [GeminiToolDefinitionResponse]
  let geminiConfig: GeminiConfigResponse
  let ephemeralToken: EphemeralTokenResponse

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case procedure
    case systemPrompt = "system_prompt"
    case tools
    case geminiConfig = "gemini_config"
    case ephemeralToken = "ephemeral_token"
  }
}

// MARK: - Voice options

struct VoiceOption: Codable, Identifiable {
  var id: String { name }
  let name: String
  let description: String
  let previewUrl: String
}

// MARK: - Local session tracking

enum SessionStatus: String, Codable {
  case inProgress = "in_progress"
  case completed
  case abandoned
}

struct SessionRecord: Codable, Identifiable {
  let id: String
  let procedureId: String
  let procedureTitle: String
  let startedAt: Date
  var completedAt: Date?
  var stepsCompleted: Int
  var totalSteps: Int
  var status: SessionStatus
}
