import Foundation

@MainActor
class ProcedureAPIService: ObservableObject {
  private var serverBaseURL: String {
    ServerEndpoint.shared.resolvedBaseURL
  }

  private let decoder: JSONDecoder = {
    let d = JSONDecoder()
    return d
  }()

  // MARK: - List procedures

  func fetchProcedures() async throws -> [ProcedureListItem] {
    guard let url = URL(string: "\(serverBaseURL)/api/procedures") else {
      throw APIError.invalidURL
    }
    let (data, _) = try await URLSession.shared.data(from: url)
    return try decoder.decode([ProcedureListItem].self, from: data)
  }

  // MARK: - Get single procedure

  func fetchProcedure(id: String) async throws -> ProcedureResponse {
    guard let url = URL(string: "\(serverBaseURL)/api/procedures/\(id)") else {
      throw APIError.invalidURL
    }
    let (data, _) = try await URLSession.shared.data(from: url)
    return try decoder.decode(ProcedureResponse.self, from: data)
  }

  // MARK: - Delete procedure

  func deleteProcedure(id: String) async throws {
    guard let url = URL(string: "\(serverBaseURL)/api/procedures/\(id)") else {
      throw APIError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw APIError.serverError
    }
  }

  // MARK: - Update procedure

  func updateProcedure(id: String, update: ProcedureUpdateRequest) async throws -> ProcedureResponse {
    guard let url = URL(string: "\(serverBaseURL)/api/procedures/\(id)") else {
      throw APIError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(update)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw APIError.serverError
    }
    return try decoder.decode(ProcedureResponse.self, from: data)
  }

  // MARK: - Update step

  func updateStep(procedureId: String, stepNumber: Int, update: StepUpdateRequest) async throws -> ProcedureResponse {
    guard let url = URL(string: "\(serverBaseURL)/api/procedures/\(procedureId)/steps/\(stepNumber)") else {
      throw APIError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(update)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw APIError.serverError
    }
    return try decoder.decode(ProcedureResponse.self, from: data)
  }

  // MARK: - Voices

  func fetchVoices() async throws -> [VoiceOption] {
    guard let url = URL(string: "\(serverBaseURL)/api/learner/voices") else {
      throw APIError.invalidURL
    }
    let (data, _) = try await URLSession.shared.data(from: url)
    let voiceDecoder = JSONDecoder()
    voiceDecoder.keyDecodingStrategy = .convertFromSnakeCase
    return try voiceDecoder.decode([VoiceOption].self, from: data)
  }

  // MARK: - Learner session

  func startLearnerSession(
    procedureId: String,
    voice: String,
    autoAdvance: Bool,
    startingStep: Int? = nil
  ) async throws -> LearnerSessionStartResponse {
    guard let url = URL(string: "\(serverBaseURL)/api/learner/session/start") else {
      throw APIError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    // Body contains mixed types (String + Bool + optional Int) so use
    // JSONSerialization rather than a homogeneous [String: String] dict.
    var body: [String: Any] = [
      "procedure_id": procedureId,
      "voice": voice,
      "auto_advance": autoAdvance,
    ]
    if let startingStep {
      body["starting_step"] = startingStep
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw APIError.serverError
    }
    return try decoder.decode(LearnerSessionStartResponse.self, from: data)
  }

  // MARK: - Context summary (for re-orienting the AI after session resumption)

  func fetchContextSummary(sessionId: String) async throws -> String {
    guard let url = URL(
      string: "\(serverBaseURL)/api/learner/session/\(sessionId)/context-summary"
    ) else {
      throw APIError.invalidURL
    }
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw APIError.serverError
    }
    struct Payload: Decodable { let summary: String }
    return try decoder.decode(Payload.self, from: data).summary
  }

  func invokeLearnerToolCall(
    sessionId: String,
    toolName: String,
    arguments: [String: Any]
  ) async throws -> [String: Any] {
    guard let url = URL(string: "\(serverBaseURL)/api/learner/session/\(sessionId)/tool-call") else {
      throw APIError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 10
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "tool_name": toolName,
      "arguments": arguments,
    ])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw APIError.serverError
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw APIError.invalidResponse
    }

    if let inner = json["result"] as? [String: Any] {
      return inner
    }
    return json
  }

  // MARK: - Troubleshoot (diagnostic) session

  func startDiagnosticSession(voice: String) async throws -> DiagnosticSessionStartResponse {
    guard let url = URL(string: "\(serverBaseURL)/api/troubleshoot/session/start") else {
      throw APIError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["voice": voice])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw APIError.serverError
    }
    return try decoder.decode(DiagnosticSessionStartResponse.self, from: data)
  }

  func fetchDiagnosticState(sessionId: String) async throws -> TroubleshootSessionState {
    guard let url = URL(string: "\(serverBaseURL)/api/troubleshoot/session/\(sessionId)/state") else {
      throw APIError.invalidURL
    }
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw APIError.serverError
    }
    return try decoder.decode(TroubleshootSessionState.self, from: data)
  }

  /// Atomically ends the diagnostic session and opens a Learner session on
  /// the matched/generated procedure. Return shape matches startLearnerSession
  /// so the phone can swap WebSockets with a single mint.
  func handoffDiagnosticToLearner(
    sessionId: String,
    procedureId: String,
    autoAdvance: Bool,
    voice: String
  ) async throws -> LearnerSessionStartResponse {
    guard let url = URL(string: "\(serverBaseURL)/api/troubleshoot/session/\(sessionId)/handoff") else {
      throw APIError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = [
      "procedure_id": procedureId,
      "auto_advance": autoAdvance,
      "voice": voice,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw APIError.serverError
    }
    return try decoder.decode(LearnerSessionStartResponse.self, from: data)
  }

  func endDiagnosticSession(sessionId: String) async {
    guard let url = URL(string: "\(serverBaseURL)/api/troubleshoot/session/\(sessionId)") else {
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    _ = try? await URLSession.shared.data(for: request)
  }

  func uploadManual(pdfURL: URL) async throws -> ManualUploadResponse {
    guard let url = URL(string: "\(serverBaseURL)/api/troubleshoot/manuals/upload") else {
      throw APIError.invalidURL
    }
    let pdfData = try Data(contentsOf: pdfURL)
    let boundary = "Boundary-\(UUID().uuidString)"
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    let filename = pdfURL.lastPathComponent
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"pdf\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: application/pdf\r\n\r\n".data(using: .utf8)!)
    body.append(pdfData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    request.httpBody = body

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw APIError.serverError
    }
    return try decoder.decode(ManualUploadResponse.self, from: data)
  }

  func pollManual(manualId: String) async throws -> ManualStatusResponse {
    guard let url = URL(string: "\(serverBaseURL)/api/troubleshoot/manuals/\(manualId)") else {
      throw APIError.invalidURL
    }
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw APIError.serverError
    }
    return try decoder.decode(ManualStatusResponse.self, from: data)
  }

  // MARK: - Base URL accessor for clip URLs

  var baseURL: String { serverBaseURL }

  enum APIError: LocalizedError {
    case invalidURL
    case serverError
    case invalidResponse

    var errorDescription: String? {
      switch self {
      case .invalidURL: return "Invalid server URL"
      case .serverError: return "Server returned an error"
      case .invalidResponse: return "Server returned an invalid response"
      }
    }
  }
}
