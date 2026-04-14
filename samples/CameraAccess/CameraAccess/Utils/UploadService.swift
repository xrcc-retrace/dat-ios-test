import Foundation

@MainActor
class UploadService: NSObject, ObservableObject, URLSessionTaskDelegate {
  @Published var uploadProgress: Double = 0
  @Published var isUploading = false
  @Published var uploadResult: ProcedureResponse?
  @Published var uploadError: String?

  // Default to local network — update this to your Mac's IP
  var serverBaseURL = "http://192.168.1.100:8000"

  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 300 // 5 min for Gemini processing
    return URLSession(configuration: config, delegate: self, delegateQueue: .main)
  }()

  func uploadRecording(fileURL: URL) async {
    guard !isUploading else { return }

    isUploading = true
    uploadProgress = 0
    uploadResult = nil
    uploadError = nil

    guard let url = URL(string: "\(serverBaseURL)/api/expert/upload") else {
      uploadError = "Invalid server URL"
      isUploading = false
      return
    }

    let boundary = UUID().uuidString
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 300

    // Build multipart body
    var body = Data()
    let filename = fileURL.lastPathComponent

    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"video\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: video/mp4\r\n\r\n".data(using: .utf8)!)

    guard let videoData = try? Data(contentsOf: fileURL) else {
      uploadError = "Failed to read recording file"
      isUploading = false
      return
    }
    body.append(videoData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    request.httpBody = body

    print("[Upload] Starting upload: \(filename) (\(videoData.count / 1024)KB) to \(serverBaseURL)")

    do {
      let (data, response) = try await session.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        uploadError = "Invalid server response"
        isUploading = false
        return
      }

      guard httpResponse.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? "no body"
        uploadError = "Server error (\(httpResponse.statusCode)): \(body)"
        isUploading = false
        return
      }

      let decoder = JSONDecoder()
      let procedure = try decoder.decode(ProcedureResponse.self, from: data)
      uploadResult = procedure
      print("[Upload] Success: \(procedure.title) (\(procedure.steps.count) steps)")
    } catch {
      uploadError = "Upload failed: \(error.localizedDescription)"
      print("[Upload] Error: \(error)")
    }

    isUploading = false
  }

  // MARK: - URLSessionTaskDelegate (upload progress)

  nonisolated func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
    Task { @MainActor in
      self.uploadProgress = progress
    }
  }
}
