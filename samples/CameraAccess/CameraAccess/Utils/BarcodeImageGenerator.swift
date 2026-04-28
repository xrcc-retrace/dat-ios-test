import CoreImage
import UIKit

enum BarcodeImageGenerator {
  private static let context = CIContext()

  /// Renders `string` as a Code 128 barcode at the requested pixel `height`,
  /// preserving sharp bar edges. Callers MUST apply `.interpolation(.none)`
  /// at the SwiftUI Image site — bilinear resampling blurs bars enough to
  /// fail real scanners.
  static func code128Image(for string: String, height: CGFloat) -> UIImage? {
    guard
      let filter = CIFilter(name: "CICode128BarcodeGenerator"),
      let data = string.data(using: .ascii)
    else { return nil }

    filter.setValue(data, forKey: "inputMessage")
    filter.setValue(7.0, forKey: "inputQuietSpace")

    guard let output = filter.outputImage else { return nil }

    let outputHeight = output.extent.height
    guard outputHeight > 0, height > 0 else { return nil }

    // X scale is fixed at 2.0 so individual bars stay >= 2 px wide on phone
    // widths; Y scale stretches to the requested visible height.
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 2.0, y: height / outputHeight))

    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}
