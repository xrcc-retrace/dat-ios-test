import Foundation

/// Drives the Expert PDF manual upload flow:
///   1. POST the PDF to /api/expert/manuals/upload (deterministic progress
///      via the underlying `URLSession.data(for:)` task — we don't expose
///      a per-byte callback since the upload is small relative to the
///      Gemini ingest that follows).
///   2. Poll /api/expert/manuals/{id} until `status` ∈ {ready, failed}.
///   3. On success, surface the new procedure_id to the caller so the
///      UI can navigate to ProcedureDetailView.
@MainActor
final class ManualUploadViewModel: ObservableObject {
  enum Phase: Equatable {
    case idle
    case uploading
    case analyzing
    case ready(procedureId: String)
    case failed(message: String)
  }

  @Published private(set) var phase: Phase = .idle

  private let api = ProcedureAPIService()
  private var pollTask: Task<Void, Never>?

  deinit {
    pollTask?.cancel()
  }

  /// Kick off the full upload + polling lifecycle. Safe to call once per VM
  /// instance; subsequent calls reset state and re-run.
  func start(pdfURL: URL, productName: String) {
    pollTask?.cancel()
    phase = .uploading

    Task { [weak self] in
      guard let self else { return }
      do {
        // The URL came from `.fileImporter`; we have to bracket access in
        // a security scope or URLSession can't read the file.
        let needsScope = pdfURL.startAccessingSecurityScopedResource()
        defer { if needsScope { pdfURL.stopAccessingSecurityScopedResource() } }

        let upload = try await self.api.uploadExpertManual(
          pdfURL: pdfURL,
          productName: productName
        )
        await MainActor.run { self.phase = .analyzing }
        await self.pollUntilDone(manualId: upload.manualId)
      } catch {
        await MainActor.run {
          self.phase = .failed(message: Self.friendlyMessage(for: error))
        }
      }
    }
  }

  func cancel() {
    pollTask?.cancel()
    pollTask = nil
    phase = .idle
  }

  private func pollUntilDone(manualId: String) async {
    pollTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        do {
          let status = try await self.api.pollExpertManual(manualId: manualId)
          switch status.status {
          case "ready":
            if let pid = status.procedureId {
              await MainActor.run { self.phase = .ready(procedureId: pid) }
            } else {
              await MainActor.run {
                self.phase = .failed(message: "Server reported ready but no procedure id was returned.")
              }
            }
            return
          case "failed":
            let msg = status.error ?? "Couldn't extract steps. The manual may be encrypted, image-only, or not a step-by-step guide."
            await MainActor.run { self.phase = .failed(message: msg) }
            return
          default:
            // "uploaded" / "processing" — keep polling.
            break
          }
        } catch {
          await MainActor.run {
            self.phase = .failed(message: Self.friendlyMessage(for: error))
          }
          return
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
      }
    }
    await pollTask?.value
  }

  private static func friendlyMessage(for error: Error) -> String {
    if let urlError = error as? URLError {
      switch urlError.code {
      case .notConnectedToInternet, .networkConnectionLost, .timedOut:
        return "Upload failed. Check your Wi-Fi and try again."
      default:
        return "Upload failed (\(urlError.code.rawValue)). Try again."
      }
    }
    return error.localizedDescription
  }
}
