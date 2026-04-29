import AVFoundation
import SwiftUI
import UIKit

/// SwiftUI wrapper around `AVCaptureVideoPreviewLayer`. Owned preview layer comes
/// from `IPhoneCameraCapture` — this view just hosts and resizes it.
struct IPhoneCameraPreview: UIViewRepresentable {
  let previewLayer: AVCaptureVideoPreviewLayer

  func makeUIView(context: Context) -> PreviewHostView {
    let view = PreviewHostView()
    view.backgroundColor = .black
    view.layer.addSublayer(previewLayer)
    return view
  }

  func updateUIView(_ uiView: PreviewHostView, context: Context) {
    uiView.previewLayer = previewLayer
  }

  final class PreviewHostView: UIView {
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    override func layoutSubviews() {
      super.layoutSubviews()
      previewLayer?.frame = bounds
    }
  }
}

/// Glasses camera-feed preview rendered on the phone screen. Mirrors the
/// iPhone-emulator experience for glasses-mode sessions: the lens HUD
/// composites over a live render of what the glasses camera sees, exactly
/// like the iPhone path renders the HUD over `AVCaptureVideoPreviewLayer`.
///
/// Stateless by design — the parent owns the `UIImage` (driven by the DAT
/// SDK's `videoFramePublisher` via `GeminiLiveSessionBase` for coaching/
/// troubleshoot sessions, or `StreamSessionViewModel` for expert recording).
/// SwiftUI re-renders this view on every frame the parent publishes.
struct GlassesCameraPreview: View {
  let image: UIImage?

  var body: some View {
    if let image {
      Image(uiImage: image)
        .resizable()
        .aspectRatio(contentMode: .fill)
    } else {
      Color.black
    }
  }
}
