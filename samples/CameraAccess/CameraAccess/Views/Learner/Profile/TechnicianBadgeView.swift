import SwiftUI

/// Industrial plant ID badge that anchors the Profile screen. All credential
/// metadata is hard-coded for the hackathon prototype. Renders a real
/// Code 128 barcode of the badge number.
///
/// Fixed typography — does not scale with Dynamic Type. A credential card
/// has a physical, fixed format; a card that grows with text size stops
/// reading as a credential. The name itself shrinks-to-fit on a single line
/// so long names stay legible without ellipsis.
struct TechnicianBadgeView: View {
  private let technicianName = "H. HWANG"
  private let badgeNumber = "RT-04287"
  private let clearanceLabel = "LV-3 · COACH-CERTIFIED"
  private let issuedLabel = "ISSUED 2026-04"
  private let validThruLabel = "VALID THRU 2027-04"

  // Opaque dark navy. Hard-coded inline rather than a token because no
  // dark-navy semantic exists and we don't want it adapting to light mode —
  // a credential is environment-agnostic.
  private let cardFill = Color(red: 0.08, green: 0.11, blue: 0.18)

  var body: some View {
    VStack(spacing: 0) {
      BadgeHeaderStrip()

      VStack(spacing: 0) {
        BadgePrimaryRow(name: technicianName, badgeNumber: badgeNumber)
          .padding(.horizontal, Spacing.xl)
          .padding(.top, Spacing.lg)

        BadgeMetadataRow(
          clearanceLabel: clearanceLabel,
          issuedLabel: issuedLabel,
          validThruLabel: validThruLabel
        )
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.sm)

        Rectangle()
          .fill(Color.white.opacity(0.12))
          .frame(height: 0.5)
          .padding(.horizontal, Spacing.xl)
          .padding(.top, Spacing.lg)

        BadgeBarcodeStrip(badgeNumber: badgeNumber)
          .padding(.horizontal, Spacing.md)
          .padding(.top, Spacing.lg)
          .padding(.bottom, Spacing.xl)
      }
    }
    .background(cardFill)
    .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .stroke(Color.appBadgeAccent.opacity(0.35), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.55), radius: 18, x: 0, y: 6)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Technician badge for \(technicianName), badge number \(badgeNumber), clearance level 3, coach certified. Issued April 2026, valid through April 2027."
    )
  }
}

// MARK: - Header strip

private struct BadgeHeaderStrip: View {
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.lg) {
      Text("RETRACE")
        .font(Font.retraceFace(.black, size: 13))
        .tracking(2.5)
        .foregroundColor(.appBadgeAccent)

      Spacer(minLength: 0)

      Text("FIELD TECHNICIAN")
        .font(Font.retraceFace(.medium, size: 10))
        .tracking(1.8)
        .foregroundColor(.white.opacity(0.55))
    }
    .padding(.horizontal, Spacing.xl)
    .frame(height: 32)
    .frame(maxWidth: .infinity)
    .background(Color.appBadgeAccent.opacity(0.15))
  }
}

// MARK: - Primary row (name + badge number)

private struct BadgePrimaryRow: View {
  let name: String
  let badgeNumber: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
      // Shrink-to-fit on a single line so long names stay legible at the
      // expense of size, instead of getting an ellipsis. 0.55 takes 26pt
      // down to ~14pt — enough headroom for ~24-char names.
      Text(name)
        .font(Font.retraceFace(.bold, size: 26))
        .tracking(0.5)
        .foregroundColor(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.55)
        .layoutPriority(1)

      Spacer(minLength: Spacing.md)

      Text(badgeNumber)
        .font(Font.retraceFace(.black, size: 18))
        .monospacedDigit()
        .tracking(1.5)
        .foregroundColor(.appBadgeAccent)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
  }
}

// MARK: - Metadata row (clearance chip + dates)

private struct BadgeMetadataRow: View {
  let clearanceLabel: String
  let issuedLabel: String
  let validThruLabel: String

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      Text(clearanceLabel)
        .font(Font.retraceFace(.semibold, size: 10))
        .tracking(1.2)
        .foregroundColor(.white.opacity(0.80))
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.xs)
        .background(Capsule().fill(Color.white.opacity(0.10)))

      Spacer(minLength: 0)

      VStack(alignment: .trailing, spacing: 2) {
        Text(issuedLabel)
          .font(Font.retraceFace(.medium, size: 10))
          .tracking(0.8)
          .monospacedDigit()
          .foregroundColor(.white.opacity(0.40))

        Text(validThruLabel)
          .font(Font.retraceFace(.medium, size: 10))
          .tracking(0.8)
          .monospacedDigit()
          .foregroundColor(.white.opacity(0.40))
      }
    }
  }
}

// MARK: - Barcode strip

private struct BadgeBarcodeStrip: View {
  let badgeNumber: String

  // 40 pt bars + 16 pt human-readable text = 56 pt total inside the white
  // strip. Re-render only when the number changes.
  private let barsHeight: CGFloat = 40

  var body: some View {
    VStack(spacing: 2) {
      Group {
        if let image = BarcodeImageGenerator.code128Image(for: badgeNumber, height: barsHeight) {
          Image(uiImage: image)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(height: barsHeight)
        } else {
          Color.clear.frame(height: barsHeight)
        }
      }

      Text(badgeNumber)
        .font(Font.retraceFace(.regular, size: 9))
        .monospacedDigit()
        .tracking(1.0)
        .foregroundColor(Color(white: 0.2))
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .fill(Color.white)
    )
    .accessibilityHidden(true)
  }
}

