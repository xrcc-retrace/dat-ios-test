import SwiftUI

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
