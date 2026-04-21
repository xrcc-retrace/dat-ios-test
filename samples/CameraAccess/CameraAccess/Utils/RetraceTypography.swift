import CoreText
import SwiftUI
import UIKit

enum RetraceFontFace: String {
  case regular = "GolosText-Regular"
  case medium = "GolosText-Medium"
  case semibold = "GolosText-SemiBold"
  case bold = "GolosText-Bold"
  case extrabold = "GolosText-ExtraBold"
  case black = "GolosText-Black"
}

extension Font {
  static func retraceFace(_ face: RetraceFontFace, size: CGFloat) -> Font {
    .custom(face.rawValue, size: size)
  }

  static func inter(_ weight: InterFontWeight, size: CGFloat, italic: Bool = false) -> Font {
    Font(InterFontResolver.uiFont(weight: weight, size: size, italic: italic))
  }

  static let retraceDisplay = Font.retraceFace(.bold, size: 34)
  static let retraceTitle1 = Font.retraceFace(.bold, size: 28)
  static let retraceTitle2 = Font.retraceFace(.bold, size: 22)
  static let retraceTitle3 = Font.retraceFace(.semibold, size: 18)
  static let retraceHeadline = Font.retraceFace(.semibold, size: 17)
  static let retraceBody = Font.retraceFace(.regular, size: 17)
  static let retraceCallout = Font.retraceFace(.regular, size: 16)
  static let retraceSubheadline = Font.retraceFace(.regular, size: 13)
  static let retraceCaption1 = Font.retraceFace(.medium, size: 12)
  static let retraceCaption2 = Font.retraceFace(.regular, size: 11)
  static let retraceOverline = Font.retraceFace(.semibold, size: 11)
}

enum InterFontWeight: CGFloat {
  case regular = 400
  case medium = 500
  case bold = 700

  var fallback: UIFont.Weight {
    switch self {
    case .regular:
      return .regular
    case .medium:
      return .medium
    case .bold:
      return .bold
    }
  }
}

private enum InterFontResolver {
  private static let fontName = "Inter-Regular"
  private static let opticalSizeMinimum: CGFloat = 14

  static func uiFont(weight: InterFontWeight, size: CGFloat, italic: Bool) -> UIFont {
    guard let baseFont = UIFont(name: fontName, size: size) else {
      return italic
        ? .italicSystemFont(ofSize: size)
        : .systemFont(ofSize: size, weight: weight.fallback)
    }

    let axes = (CTFontCopyVariationAxes(baseFont as CTFont) as? [[CFString: Any]]) ?? []
    var variations: [NSNumber: NSNumber] = [:]

    if let axisID = axisIdentifier(containing: "weight", in: axes) {
      variations[axisID] = NSNumber(value: Float(weight.rawValue))
    }
    if let axisID = axisIdentifier(containing: "optical", in: axes) {
      variations[axisID] = NSNumber(value: Float(max(size, opticalSizeMinimum)))
    }
    if let axisID = axisIdentifier(containing: "ital", in: axes) {
      variations[axisID] = NSNumber(value: italic ? 1.0 : 0.0)
    }

    guard !variations.isEmpty else { return baseFont }

    let descriptor = baseFont.fontDescriptor.addingAttributes([
      kCTFontVariationAttribute as UIFontDescriptor.AttributeName: variations,
    ])
    return UIFont(descriptor: descriptor, size: size)
  }

  private static func axisIdentifier(containing nameFragment: String, in axes: [[CFString: Any]]) -> NSNumber? {
    axes.first {
      (($0[kCTFontVariationAxisNameKey] as? String) ?? "")
        .localizedCaseInsensitiveContains(nameFragment)
    }?[kCTFontVariationAxisIdentifierKey] as? NSNumber
  }
}
