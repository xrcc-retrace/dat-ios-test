import Foundation

struct ProcedureResponse: Codable {
  let id: String
  let title: String
  let description: String
  let steps: [ProcedureStepResponse]
  let totalDuration: Double
  let createdAt: String

  enum CodingKeys: String, CodingKey {
    case id, title, description, steps
    case totalDuration = "total_duration"
    case createdAt = "created_at"
  }
}

struct ProcedureStepResponse: Codable {
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
