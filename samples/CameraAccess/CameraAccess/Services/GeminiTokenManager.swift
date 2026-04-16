import Foundation

/// Manages ephemeral Gemini Live API tokens. Uses Swift actor for
/// built-in concurrency safety — no manual locking needed.
actor GeminiTokenManager {
  private let sessionId: String
  private let serverBaseURL: String
  private var currentToken: EphemeralTokenResponse?
  private var refreshTask: Task<EphemeralTokenResponse, Error>?

  /// How far before expiry to proactively refresh (seconds).
  private let refreshBuffer: TimeInterval = 300  // 5 minutes

  private let decoder: JSONDecoder = {
    let d = JSONDecoder()
    return d
  }()

  init(sessionId: String, serverBaseURL: String) {
    self.sessionId = sessionId
    self.serverBaseURL = serverBaseURL
  }

  /// Seed with the token from the initial session/start response.
  func setInitialToken(_ token: EphemeralTokenResponse) {
    currentToken = token
    refreshTask = nil
  }

  /// Return a valid token. Refreshes proactively if near expiry.
  func validToken() async throws -> EphemeralTokenResponse {
    if let token = currentToken, !isExpiringSoon(token) {
      return token
    }
    return try await forceRefresh()
  }

  /// Force-refresh: called after an auth error on the WebSocket.
  /// Deduplicates concurrent calls — only one fetch runs at a time.
  func forceRefresh() async throws -> EphemeralTokenResponse {
    if let existing = refreshTask {
      return try await existing.value
    }

    let task = Task<EphemeralTokenResponse, Error> {
      let token = try await fetchTokenFromServer()
      return token
    }
    refreshTask = task

    do {
      let token = try await task.value
      currentToken = token
      refreshTask = nil
      return token
    } catch {
      refreshTask = nil
      throw error
    }
  }

  // MARK: - Private

  private func isExpiringSoon(_ token: EphemeralTokenResponse) -> Bool {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let expiry = formatter.date(from: token.expiresAt) else {
      // Can't parse — treat as expired.
      return true
    }
    return expiry.timeIntervalSinceNow < refreshBuffer
  }

  private func fetchTokenFromServer() async throws -> EphemeralTokenResponse {
    guard let url = URL(string: "\(serverBaseURL)/api/learner/session/\(sessionId)/token") else {
      throw TokenError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 15

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
      throw TokenError.serverError(statusCode: statusCode)
    }

    return try decoder.decode(EphemeralTokenResponse.self, from: data)
  }

  enum TokenError: LocalizedError {
    case invalidURL
    case serverError(statusCode: Int)

    var errorDescription: String? {
      switch self {
      case .invalidURL:
        return "Invalid server URL for token refresh"
      case .serverError(let code):
        return "Token refresh failed (HTTP \(code))"
      }
    }
  }
}
