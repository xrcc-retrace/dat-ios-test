import AVFoundation
import Foundation

@MainActor
class AudioCaptureManager: ObservableObject {
  @Published var isCapturing = false
  @Published var isBluetoothConnected = false

  private let engine = AVAudioEngine()
  private var inputNode: AVAudioInputNode { engine.inputNode }

  /// Called on the audio capture queue with each PCM buffer
  var onAudioBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

  /// The actual hardware sample rate (read after configureAudioSession)
  var hardwareSampleRate: Double {
    AVAudioSession.sharedInstance().sampleRate
  }

  /// The hardware input format (read after configureAudioSession + engine prep)
  var inputFormat: AVAudioFormat {
    inputNode.inputFormat(forBus: 0)
  }

  init() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRouteChange),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Audio Session

  func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
      )
      try session.setActive(true)
      checkBluetoothRoute()
      print("[AudioCapture] Audio session configured. Sample rate: \(session.sampleRate)")
    } catch {
      print("[AudioCapture] Failed to configure audio session: \(error)")
    }
  }

  // MARK: - Permissions

  func requestMicrophonePermission() async -> Bool {
    return await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  // MARK: - Capture

  func startCapture() {
    guard !isCapturing else { return }

    configureAudioSession()

    // Use nil format to accept the hardware's native format
    // This avoids format mismatch errors with Bluetooth HFP devices
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
      self?.onAudioBuffer?(buffer, time)
    }

    do {
      try engine.start()
      isCapturing = true
      logInputAudioRoute()
      print("[AudioCapture] Audio engine started")
    } catch {
      print("[AudioCapture] Audio engine start error: \(error)")
      inputNode.removeTap(onBus: 0)
    }
  }

  func stopCapture() {
    guard isCapturing else { return }
    inputNode.removeTap(onBus: 0)
    engine.stop()
    isCapturing = false
    print("[AudioCapture] Audio engine stopped")
  }

  // MARK: - Route Monitoring

  @objc private func handleRouteChange(notification: Notification) {
    guard let info = notification.userInfo,
          let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
    else { return }

    switch reason {
    case .oldDeviceUnavailable:
      print("[AudioCapture] Audio device disconnected")
      Task { @MainActor in
        self.checkBluetoothRoute()
      }
    case .newDeviceAvailable:
      print("[AudioCapture] New audio device available")
      Task { @MainActor in
        self.checkBluetoothRoute()
      }
    default:
      break
    }
  }

  private func checkBluetoothRoute() {
    let route = AVAudioSession.sharedInstance().currentRoute
    let hasBluetooth = route.inputs.contains { input in
      input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP
    }
    isBluetoothConnected = hasBluetooth
  }

  private func logInputAudioRoute() {
    let route = AVAudioSession.sharedInstance().currentRoute
    for input in route.inputs {
      print("[AudioCapture] Input device: \(input.portName) (type: \(input.portType.rawValue))")
      if input.portType == .bluetoothHFP {
        print("[AudioCapture] ✓ Bluetooth HFP (glasses mic)")
      } else if input.portType == .builtInMic {
        print("[AudioCapture] ⚠ Using built-in phone mic")
      }
    }
  }
}
