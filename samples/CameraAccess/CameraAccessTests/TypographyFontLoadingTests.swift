import UIKit
import XCTest

@testable import CameraAccess

final class TypographyFontLoadingTests: XCTestCase {
  func testBundledGolosFontsAreRegistered() {
    let expectedFonts = [
      "GolosText-Regular",
      "GolosText-Medium",
      "GolosText-SemiBold",
      "GolosText-Bold",
      "GolosText-ExtraBold",
      "GolosText-Black",
    ]

    let registeredFonts = Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String]
    XCTAssertEqual(
      registeredFonts ?? [],
      [
        "GolosText-Regular.ttf",
        "GolosText-Medium.ttf",
        "GolosText-SemiBold.ttf",
        "GolosText-Bold.ttf",
        "GolosText-ExtraBold.ttf",
        "GolosText-Black.ttf",
      ]
    )

    for fontName in expectedFonts {
      XCTAssertNotNil(UIFont(name: fontName, size: 16), "Expected bundled font to load: \(fontName)")
    }
  }
}
