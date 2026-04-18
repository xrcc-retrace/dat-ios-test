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
