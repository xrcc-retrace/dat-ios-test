import AVFoundation
import MWDATCore
import SwiftUI

/// Expert recording screen — transport-agnostic.
///
/// Both transports render the same `ExpertRecordingLayout` with the same
/// HUD (`ExpertNarrationTipPage`) and the same chrome (close button, mic
/// badge, Start CTA, recording review sheet). Only the camera content
/// layer differs:
///   • `.iPhone` → `IPhoneCameraPreview(previewLayer:)` over an
///     `AVCaptureVideoPreviewLayer`
///   • `.glasses` → `GlassesCameraPreview(image:)` over the DAT SDK's
///     glasses video stream
///
/// The two paths can't share a single `@StateObject` since the underlying
/// VMs differ, so the body delegates to one of two private engine
/// sub-views below. Both engines pull the HUD + chrome bodies from the
/// shared `expertRecordingHUD` / `expertRecordingChrome` helpers, so the
/// visual structure is guaranteed identical and any change to either
/// shows up on both transports.
struct IPhoneRecordingView: View {
  let transport: CaptureTransport
  let wearables: WearablesInterface
  let uploadService: UploadService
  let onAcknowledgeProcedure: () -> Void
  let onRecordingComplete: (URL, TimeInterval) -> Void

  init(
    transport: CaptureTransport,
    wearables: WearablesInterface,
    uploadService: UploadService,
    onAcknowledgeProcedure: @escaping () -> Void,
    onRecordingComplete: @escaping (URL, TimeInterval) -> Void
  ) {
    self.transport = transport
    self.wearables = wearables
    self.uploadService = uploadService
    self.onAcknowledgeProcedure = onAcknowledgeProcedure
    self.onRecordingComplete = onRecordingComplete
  }

  var body: some View {
    switch transport {
    case .iPhone:
      IPhoneRecordingEngine(
        uploadService: uploadService,
        onAcknowledgeProcedure: onAcknowledgeProcedure,
        onRecordingComplete: onRecordingComplete
      )
    case .glasses:
      GlassesRecordingEngine(
        wearables: wearables,
        uploadService: uploadService,
        onAcknowledgeProcedure: onAcknowledgeProcedure,
        onRecordingComplete: onRecordingComplete
      )
    }
  }
}

// MARK: - iPhone engine

/// Drives the iPhone-camera recording flow. The `@StateObject` VM is
/// instantiated lazily by SwiftUI, so creating two engine views (only one
/// of which is ever rendered at a time, per the parent's transport
/// switch) costs nothing for the inactive transport.
private struct IPhoneRecordingEngine: View {
  let onAcknowledgeProcedure: () -> Void
  let onRecordingComplete: (URL, TimeInterval) -> Void

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var appOrientationController: AppOrientationController
  @StateObject private var viewModel: IPhoneExpertRecordingViewModel

  @AppStorage("debugMode") private var debugMode: Bool = false
  @AppStorage("hudAdditiveBlend") private var hudAdditiveBlend: Bool = false
  @State private var currentInterfaceOrientation: UIInterfaceOrientation = .portrait
  @State private var expertPageIndex: Int = 0

  init(
    uploadService: UploadService,
    onAcknowledgeProcedure: @escaping () -> Void,
    onRecordingComplete: @escaping (URL, TimeInterval) -> Void
  ) {
    self._viewModel = StateObject(
      wrappedValue: IPhoneExpertRecordingViewModel(uploadService: uploadService)
    )
    self.onAcknowledgeProcedure = onAcknowledgeProcedure
    self.onRecordingComplete = onRecordingComplete
  }

  var body: some View {
    ExpertRecordingLayout {
      IPhoneCameraPreview(previewLayer: viewModel.previewLayer)
    } hud: {
      expertRecordingHUD(
        recordingManager: viewModel.recordingManager,
        hudViewModel: viewModel.hudViewModel,
        debugMode: debugMode,
        hudAdditiveBlend: hudAdditiveBlend,
        pageIndex: $expertPageIndex,
        onStop: {
          // Stop = capture mode is over. Finalize the mp4, then hand the
          // URL up so the parent can dismiss this view (camera + audio
          // teardown fires on `onDisappear`) and present the review as
          // a sibling full-screen cover. No camera running underneath
          // the review — that was the old sheet-on-top-of-recording-view
          // pattern, which kept the AVCaptureSession alive for the full
          // upload + procedure-review flow.
          Task {
            if let result = await viewModel.stopRecording() {
              onRecordingComplete(result.0, result.1)
            }
          }
        }
      )
    } chrome: {
      expertRecordingChrome(
        recordingManager: viewModel.recordingManager,
        hudViewModel: viewModel.hudViewModel,
        isPreviewLive: viewModel.isPreviewLive,
        debugMode: debugMode,
        onClose: { dismiss() },
        onStart: {
          // Always portrait/natural orientation. The pinned-landscape mode
          // was deprecated — rotating the phone gives the same result via
          // the orientation observer below.
          viewModel.startRecording(landscape: false)
        }
      )
    }
    .animation(.easeInOut(duration: 0.18), value: viewModel.recordingManager.isHUDActive)
    .task {
      await viewModel.prepare()
    }
    .onAppear {
      // Broaden the allowed orientation mask so SwiftUI chrome can follow
      // the phone into landscape, same as the learner coaching flow.
      appOrientationController.setAllowed([.portrait, .landscapeLeft, .landscapeRight])
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
      let resolved = resolveInterfaceOrientation()
      currentInterfaceOrientation = resolved
      // Seed the preview from the scene's actual interface orientation so
      // the layout matches the current phone orientation.
      viewModel.camera.setPreviewInterfaceOrientation(resolved)
    }
    .onDisappear {
      Task { await viewModel.teardown() }
      UIDevice.current.endGeneratingDeviceOrientationNotifications()
      appOrientationController.unlock()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      let resolved = resolveInterfaceOrientation()
      currentInterfaceOrientation = resolved
      viewModel.camera.setPreviewInterfaceOrientation(resolved)
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
  }
}

// MARK: - Glasses engine

/// Drives the glasses-camera recording flow. Body shape mirrors the iPhone
/// engine 1-for-1 — the only difference is the camera preview view and the
/// fact that there's no AVCaptureSession orientation to forward.
private struct GlassesRecordingEngine: View {
  let onAcknowledgeProcedure: () -> Void
  let onRecordingComplete: (URL, TimeInterval) -> Void

  @Environment(\.dismiss) private var dismiss
  @StateObject private var viewModel: StreamSessionViewModel

  @AppStorage("debugMode") private var debugMode: Bool = false
  @AppStorage("hudAdditiveBlend") private var hudAdditiveBlend: Bool = false
  @State private var expertPageIndex: Int = 0

  init(
    wearables: WearablesInterface,
    uploadService: UploadService,
    onAcknowledgeProcedure: @escaping () -> Void,
    onRecordingComplete: @escaping (URL, TimeInterval) -> Void
  ) {
    self.onAcknowledgeProcedure = onAcknowledgeProcedure
    self.onRecordingComplete = onRecordingComplete
    self._viewModel = StateObject(
      wrappedValue: StreamSessionViewModel(wearables: wearables, uploadService: uploadService)
    )
  }

  var body: some View {
    ExpertRecordingLayout {
      GlassesCameraPreview(image: viewModel.currentVideoFrame)
    } hud: {
      expertRecordingHUD(
        recordingManager: viewModel.recordingManager,
        hudViewModel: viewModel.hudViewModel,
        debugMode: debugMode,
        hudAdditiveBlend: hudAdditiveBlend,
        pageIndex: $expertPageIndex,
        onStop: {
          // See IPhoneRecordingEngine — same hand-off pattern: stop
          // finalizes the mp4, then we hand the URL up so the parent
          // can dismiss this view (teardown stops the glasses stream
          // and hand-tracking) and present the review as a sibling
          // full-screen cover with no glasses pipeline running.
          Task {
            if let result = await viewModel.stopRecording() {
              onRecordingComplete(result.0, result.1)
            }
          }
        }
      )
    } chrome: {
      // Glasses-only: gate the Start CTA on `isReadyToRecord` (set
      // true after the silent warmup cycle in `prepare()`) AND
      // `isPreviewLive`. The chrome param is named `isPreviewLive`
      // for shape-parity with the iPhone engine, but we feed both
      // signals into it so the disabled state covers warmup too.
      expertRecordingChrome(
        recordingManager: viewModel.recordingManager,
        hudViewModel: viewModel.hudViewModel,
        isPreviewLive: viewModel.isPreviewLive && viewModel.isReadyToRecord,
        debugMode: debugMode,
        onClose: { dismiss() },
        onStart: { viewModel.startRecording(landscape: false) }
      )
    }
    .animation(.easeInOut(duration: 0.18), value: viewModel.recordingManager.isHUDActive)
    .task {
      await viewModel.prepare()
    }
    .onDisappear {
      Task { await viewModel.teardown() }
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
  }
}

// MARK: - Shared HUD body

/// Lens content shared by both engines. Hidden until `isHUDActive` flips so
/// pre-recording the user sees just the camera preview + Start CTA — no
/// narration card, no stop pill. Same fade-in semantics on both transports.
///
/// `@MainActor` because it reads `@MainActor`-isolated state on
/// `recordingManager` / `hudViewModel`. SwiftUI view bodies are
/// MainActor-isolated, so callers satisfy this for free.
@MainActor
@ViewBuilder
private func expertRecordingHUD(
  recordingManager: ExpertRecordingManager,
  hudViewModel: ExpertRecordingHUDViewModel,
  debugMode: Bool,
  hudAdditiveBlend: Bool,
  pageIndex: Binding<Int>,
  onStop: @escaping () -> Void
) -> some View {
  if recordingManager.isHUDActive {
    RayBanHUDEmulator(
      pageCount: 1,
      pageIndex: pageIndex,
      showBoundary: debugMode,
      additiveBlend: hudAdditiveBlend,
      additiveSurfaceVariant: .lowTint,
      enableDismissGesture: true
    ) { _ in
      ExpertNarrationTipPage(
        recordingManager: recordingManager,
        hud: hudViewModel,
        onStop: onStop
      )
    }
    .transition(.opacity)
  }
}

// MARK: - Shared chrome body

/// Non-HUD overlays shared by both engines. Two phases:
///   • Pre-recording — close button (top-left), mic-source badge (top-right),
///     Start CTA (bottom).
///   • Recording — chrome stays empty above the lens. Recording status,
///     audio meter, mic-source, and stop pill all live *inside* the lens
///     alongside the narration card. See `ExpertNarrationTipPage`.
///
/// `@MainActor` for the same reason as `expertRecordingHUD` — reads
/// MainActor-isolated state on `recordingManager` / `hudViewModel`.
@MainActor
@ViewBuilder
private func expertRecordingChrome(
  recordingManager: ExpertRecordingManager,
  hudViewModel: ExpertRecordingHUDViewModel,
  isPreviewLive: Bool,
  debugMode: Bool,
  onClose: @escaping () -> Void,
  onStart: @escaping () -> Void
) -> some View {
  if !isPreviewLive {
    ProgressView()
      .scaleEffect(1.5)
      .tint(.textPrimary)
  }

  // Top row: pre-recording shows close (top-left) + mic-source badge
  // (top-right). When recording starts, the mic badge moves *into* the
  // lens so chrome stops rendering it to avoid double-up.
  VStack {
    HStack(alignment: .top) {
      if !recordingManager.isHUDActive {
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.textPrimary)
            .frame(width: 36, height: 36)
            .glassPanel(cornerRadius: Radius.full)
        }
        .padding(.leading, 20)

        Spacer()

        ExpertHUDMicSourceBadge(micSource: hudViewModel.micSource)
          .padding(.trailing, 20)
      } else {
        Spacer()
      }
    }
    .padding(.top, 20)

    Spacer()
  }

  // Pre-recording bottom: Start CTA only.
  if !recordingManager.isHUDActive {
    VStack(spacing: 12) {
      Spacer()
      ExpertStartRecordingButton(
        isStarting: recordingManager.isStarting,
        isEnabled: isPreviewLive,
        onStart: onStart
      )
    }
    .padding(.all, 24)
  }

  // Hand-tracking dev overlay — landmark dots, pinch-drag cross, event
  // log. Sits above the rest of chrome but allows hit-testing through.
  if debugMode {
    HandGestureDebugStack(provider: HandGestureService.shared)
  }
}

// MARK: - Start button (pre-recording only)

private struct ExpertStartRecordingButton: View {
  let isStarting: Bool
  let isEnabled: Bool
  let onStart: () -> Void

  var body: some View {
    CustomButton(
      title: isStarting ? "Starting…" : "Start recording",
      style: .primary,
      isDisabled: !isEnabled || isStarting,
      action: onStart
    )
  }
}

// MARK: - Shared helpers

private func resolveInterfaceOrientation() -> UIInterfaceOrientation {
  let scene = UIApplication.shared.connectedScenes
    .compactMap { $0 as? UIWindowScene }
    .first(where: { $0.activationState == .foregroundActive })
    ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
  return scene?.interfaceOrientation ?? .portrait
}
