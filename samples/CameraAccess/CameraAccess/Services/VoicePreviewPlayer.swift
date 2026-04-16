import AVFoundation
import SwiftUI

@MainActor
class VoicePreviewPlayer: NSObject, ObservableObject {
  @Published var currentlyPlaying: String?
  @Published var isLoading = false

  private var audioPlayer: AVAudioPlayer?
  private var playbackDelegate: PlaybackDelegate?

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
        let (data, _) = try await URLSession.shared.data(from: url)

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
