import AVFoundation

final class WorkflowPlaybackAudioSession {
  func activate() {
    let session = AVAudioSession.sharedInstance()

    do {
      try session.setCategory(.playback, mode: .moviePlayback, options: [])
      try session.setActive(true)
    } catch {
      print("[WorkflowPlaybackAudioSession] Failed to activate playback audio session: \(error)")
    }
  }

  func deactivate() {
    do {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      print("[WorkflowPlaybackAudioSession] Failed to deactivate playback audio session: \(error)")
    }
  }
}
