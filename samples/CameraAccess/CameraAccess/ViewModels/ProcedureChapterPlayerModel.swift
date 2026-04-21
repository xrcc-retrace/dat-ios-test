import AVFoundation
import Combine

struct ProcedurePlaybackSummary: Equatable {
  enum Style: Equatable {
    case primary
    case secondary
  }

  let title: String
  let subtitle: String?
  let symbolName: String
  let style: Style
}

final class ProcedureChapterPlayerModel: ObservableObject {
  @Published private(set) var player: AVPlayer?
  @Published private(set) var sourceVideoURL: URL?
  @Published private(set) var activeStepNumber: Int?

  private let playbackAudioSession = WorkflowPlaybackAudioSession()
  private var steps: [ProcedureStepResponse] = []
  private var timeObserverToken: Any?

  deinit {
    removeTimeObserver()
    playbackAudioSession.deactivate()
  }

  var activeStep: ProcedureStepResponse? {
    steps.first { $0.stepNumber == activeStepNumber }
  }

  var playbackSummary: ProcedurePlaybackSummary {
    if let step = activeStep {
      return ProcedurePlaybackSummary(
        title: "Step \(step.stepNumber): \(step.title)",
        subtitle: step.formattedTimeRange,
        symbolName: "play.circle.fill",
        style: .primary
      )
    }

    if sourceVideoURL != nil {
      return ProcedurePlaybackSummary(
        title: "Watch the full workflow or tap a step to jump in.",
        subtitle: nil,
        symbolName: "film",
        style: .secondary
      )
    }

    return ProcedurePlaybackSummary(
      title: "Review step details below while the source video is unavailable.",
      subtitle: nil,
      symbolName: "video.slash",
      style: .secondary
    )
  }

  func configure(procedure: ProcedureResponse, serverBaseURL: String) {
    steps = procedure.orderedSteps

    let resolvedURL = procedure.sourceVideoURL(serverBaseURL: serverBaseURL)
    let needsNewPlayer = resolvedURL != sourceVideoURL
    sourceVideoURL = resolvedURL

    if resolvedURL != nil {
      playbackAudioSession.activate()
    } else {
      playbackAudioSession.deactivate()
    }

    if needsNewPlayer {
      rebuildPlayer(with: resolvedURL)
    } else {
      refreshActiveStep(for: player?.currentTime().seconds ?? 0)
    }
  }

  func playStep(_ step: ProcedureStepResponse) {
    seek(to: step.timestampStart, autoplay: true)
  }

  func pause() {
    player?.pause()
  }

  func endPlaybackSession() {
    playbackAudioSession.deactivate()
  }

  func seek(to seconds: Double, autoplay: Bool) {
    guard let player else { return }

    let target = CMTime(seconds: seconds, preferredTimescale: 600)
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    refreshActiveStep(for: seconds)

    if autoplay {
      player.play()
    }
  }

  private func rebuildPlayer(with url: URL?) {
    removeTimeObserver()
    player?.pause()
    player = nil

    guard let url else {
      activeStepNumber = nil
      return
    }

    let player = AVPlayer(url: url)
    player.actionAtItemEnd = .pause
    self.player = player
    addTimeObserver(to: player)
    refreshActiveStep(for: 0)
  }

  private func addTimeObserver(to player: AVPlayer) {
    let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
    timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
      self?.refreshActiveStep(for: time.seconds)
    }
  }

  private func removeTimeObserver() {
    if let timeObserverToken, let player {
      player.removeTimeObserver(timeObserverToken)
    }
    timeObserverToken = nil
  }

  private func refreshActiveStep(for time: Double) {
    guard time.isFinite else {
      activeStepNumber = nil
      return
    }

    activeStepNumber = Self.activeStep(at: time, sortedSteps: steps)?.stepNumber
  }

  static func activeStep(at time: Double, steps: [ProcedureStepResponse]) -> ProcedureStepResponse? {
    activeStep(at: time, sortedSteps: steps.sortedByTimestampStart)
  }

  private static func activeStep(
    at time: Double,
    sortedSteps: [ProcedureStepResponse]
  ) -> ProcedureStepResponse? {
    guard time >= 0 else { return nil }

    var currentStep: ProcedureStepResponse?

    for step in sortedSteps {
      if time >= step.timestampStart {
        currentStep = step
      } else {
        break
      }
    }

    return currentStep
  }
}

extension ProcedureResponse {
  var orderedSteps: [ProcedureStepResponse] {
    steps.sortedByTimestampStart
  }

  func sourceVideoURL(serverBaseURL: String) -> URL? {
    let filename = sourceVideo ?? "\(id).mp4"
    return URL(string: "\(serverBaseURL)/api/uploads/\(filename)")
  }
}

extension Array where Element == ProcedureStepResponse {
  var sortedByTimestampStart: [ProcedureStepResponse] {
    sorted { $0.timestampStart < $1.timestampStart }
  }
}
