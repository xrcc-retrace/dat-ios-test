import Foundation

@MainActor
class UploadService: NSObject, ObservableObject, URLSessionTaskDelegate {
  @Published var uploadProgress: Double = 0
  @Published var isUploading = false
  @Published var isProcessing = false
  @Published var uploadResult: ProcedureResponse?
  @Published var uploadError: String?

  var serverBaseURL: String {
    ServerEndpoint.shared.resolvedBaseURL
  }

  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.default
    // Cloud uploads of 3-minute expert videos (~150-250 MB) over typical
    // home upload (10-30 Mbps) take 40-160 s — well past the old 60 s cap.
    // Bump both: per-request controls idle / response-wait time, resource
    // controls the total upload window.
    config.timeoutIntervalForRequest = 600
    config.timeoutIntervalForResource = 3600
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
    request.timeoutInterval = 600

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

      guard httpResponse.statusCode == 200 || httpResponse.statusCode == 202 else {
        let body = String(data: data, encoding: .utf8) ?? "no body"
        uploadError = "Server error (\(httpResponse.statusCode)): \(body)"
        isUploading = false
        return
      }

      let decoder = JSONDecoder()
      let uploadResp = try decoder.decode(UploadResponse.self, from: data)
      print("[Upload] Accepted: procedure \(uploadResp.id), status: \(uploadResp.status)")

      isUploading = false
      isProcessing = true

      // Poll for completion
      await pollForResult(procedureId: uploadResp.id)

    } catch {
      uploadError = "Upload failed: \(error.localizedDescription)"
      print("[Upload] Error: \(error)")
      isUploading = false
    }
  }

  private func pollForResult(procedureId: String) async {
    guard let pollURL = URL(string: "\(serverBaseURL)/api/procedures/\(procedureId)") else {
      uploadError = "Invalid server URL for polling"
      isProcessing = false
      return
    }

    let decoder = JSONDecoder()

    while isProcessing {
      try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

      do {
        let (data, _) = try await URLSession.shared.data(from: pollURL)
        let procedure = try decoder.decode(ProcedureResponse.self, from: data)

        if procedure.status == "completed" || procedure.status == "completed_partial" {
          uploadResult = procedure
          isProcessing = false
          let suffix = procedure.status == "completed_partial" ? " (some clips failed)" : ""
          print("[Upload] Processing complete: \(procedure.title) (\(procedure.steps.count) steps)\(suffix)")
          return
        } else if procedure.status == "failed" {
          uploadError = procedure.errorMessage ?? "Processing failed"
          isProcessing = false
          return
        }
        // status == "processing" → continue polling
      } catch {
        uploadError = "Lost connection to server: \(error.localizedDescription)"
        isProcessing = false
        return
      }
    }
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
