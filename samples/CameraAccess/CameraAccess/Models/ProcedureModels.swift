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
  // Filename of the original upload (e.g. "{uuid}.mov"). Optional for
  // compatibility with older servers that don't return this field.
  let sourceVideo: String?

  enum CodingKeys: String, CodingKey {
    case id, title, description, steps, status
    case totalDuration = "total_duration"
    case createdAt = "created_at"
    case errorMessage = "error_message"
    case sourceVideo = "source_video"
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
  let errorCriteria: [String]
  let clipUrl: String?

  enum CodingKeys: String, CodingKey {
    case title, description, tips, warnings
    case stepNumber = "step_number"
    case timestampStart = "timestamp_start"
    case timestampEnd = "timestamp_end"
    case errorCriteria = "error_criteria"
    case clipUrl = "clip_url"
  }

  init(
    stepNumber: Int,
    title: String,
    description: String,
    timestampStart: Double,
    timestampEnd: Double,
    tips: [String] = [],
    warnings: [String] = [],
    errorCriteria: [String] = [],
    clipUrl: String? = nil
  ) {
    self.stepNumber = stepNumber
    self.title = title
    self.description = description
    self.timestampStart = timestampStart
    self.timestampEnd = timestampEnd
    self.tips = tips
    self.warnings = warnings
    self.errorCriteria = errorCriteria
    self.clipUrl = clipUrl
  }

  // Custom decoder so old servers that predate the error_criteria column
  // don't break the client — missing / null field decodes to []. New
  // servers always emit a list (possibly empty).
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    stepNumber = try c.decode(Int.self, forKey: .stepNumber)
    title = try c.decode(String.self, forKey: .title)
    description = try c.decode(String.self, forKey: .description)
    timestampStart = try c.decode(Double.self, forKey: .timestampStart)
    timestampEnd = try c.decode(Double.self, forKey: .timestampEnd)
    tips = try c.decode([String].self, forKey: .tips)
    warnings = try c.decode([String].self, forKey: .warnings)
    errorCriteria = try c.decodeIfPresent([String].self, forKey: .errorCriteria) ?? []
    clipUrl = try c.decodeIfPresent(String.self, forKey: .clipUrl)
  }

  var hasAnyInsights: Bool {
    !tips.isEmpty || !warnings.isEmpty || !errorCriteria.isEmpty
  }

  var insightCategoryCount: Int {
    [tips, warnings, errorCriteria].filter { !$0.isEmpty }.count
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
  var errorCriteria: [String]?

  enum CodingKeys: String, CodingKey {
    case title, description, tips, warnings
    case timestampStart = "timestamp_start"
    case timestampEnd = "timestamp_end"
    case errorCriteria = "error_criteria"
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
