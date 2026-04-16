import Foundation

@MainActor
class ProcedureAPIService: ObservableObject {
  private var serverBaseURL: String {
    UserDefaults.standard.string(forKey: "serverBaseURL") ?? "http://192.168.1.100:8000"
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

  func startLearnerSession(procedureId: String, voice: String) async throws -> LearnerSessionStartResponse {
    guard let url = URL(string: "\(serverBaseURL)/api/learner/session/start") else {
      throw APIError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: String] = ["procedure_id": procedureId, "voice": voice]
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw APIError.serverError
    }
    return try decoder.decode(LearnerSessionStartResponse.self, from: data)
  }

  // MARK: - Base URL accessor for clip URLs

  var baseURL: String { serverBaseURL }

  enum APIError: LocalizedError {
    case invalidURL
    case serverError

    var errorDescription: String? {
      switch self {
      case .invalidURL: return "Invalid server URL"
      case .serverError: return "Server returned an error"
      }
    }
  }
}
