import AVFoundation
import CryptoKit
import SwiftUI

@MainActor
class VoicePreviewPlayer: NSObject, ObservableObject {
  @Published var currentlyPlaying: String?
  @Published var isLoading = false

  private var audioPlayer: AVAudioPlayer?
  private var playbackDelegate: PlaybackDelegate?

  /// Disk cache for voice WAVs — under .cachesDirectory so iOS can purge
  /// under pressure. Belt-and-braces with URLCache: this gives us a hard
  /// guarantee of zero-network replay, which the WAV size (~50 KB × 8
  /// voices) easily affords.
  private static let cacheDirectory: URL = {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent("RetraceVoicePreviews", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  private static func diskPath(for url: URL) -> URL {
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return cacheDirectory.appendingPathComponent("\(hex).wav")
  }

  func play(voiceName: String, url: URL) {
    // If already playing this voice, stop it
    if currentlyPlaying == voiceName {
      stop()
      return
    }

    stop()
    isLoading = true
    currentlyPlaying = voiceName

    Task {
      do {
        let data = try await Self.loadData(for: url)

        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)

        let player = try AVAudioPlayer(data: data)
        let delegate = PlaybackDelegate { [weak self] in
          self?.currentlyPlaying = nil
        }
        player.delegate = delegate

        self.audioPlayer = player
        self.playbackDelegate = delegate
        self.isLoading = false
        player.play()
      } catch {
        self.isLoading = false
        self.currentlyPlaying = nil
      }
    }
  }

  private static func loadData(for url: URL) async throws -> Data {
    let path = diskPath(for: url)
    if let cached = try? Data(contentsOf: path) {
      return cached
    }
    var request = URLRequest(url: url)
    request.cachePolicy = .returnCacheDataElseLoad
    let (data, _) = try await URLSession.shared.data(for: request)
    try? data.write(to: path, options: .atomic)
    return data
  }

  func stop() {
    audioPlayer?.stop()
    audioPlayer = nil
    playbackDelegate = nil
    currentlyPlaying = nil
    isLoading = false
  }
}

// MARK: - Delegate

private class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
  let onFinish: () -> Void

  init(onFinish: @escaping () -> Void) {
    self.onFinish = onFinish
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    DispatchQueue.main.async { self.onFinish() }
  }
}
