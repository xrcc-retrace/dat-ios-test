import SwiftUI

/// Recede-and-arrive overlay shown on top of `TroubleshootIdentifyPage`
/// when Gemini's `identify_product` returns a candidate but the user
/// hasn't yet confirmed. Mirrors `CoachingExitConfirmationOverlay`'s
/// pattern from the design system.
///
/// Default focus is on "That's it" since the forward path is the most
/// likely user intent and neither option is destructive — re-identifying
/// just resets local state and nudges Gemini to try again.
struct TroubleshootConfirmOverlay: View {
  let product: IdentifiedProduct
  let onConfirm: () -> Void
  let onReject: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      deviceGroup
      actionGroup
    }
    .padding(RayBanHUDLayoutTokens.contentPadding)
    .frame(maxWidth: 280)
    // Standard panel surface — the recede recipe on the underlying
    // page (scale 0.92, opacity 0.32, blur 6) is what makes the
    // overlay read as foreground.
    .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
    // Focus engine: push the overlay's handler on appear, pop on
    // disappear. `defaultFocus = .confirmIdentification` lands the cursor
    // on "That's it" automatically. On pop, the underlying identify-page
    // handler's bottom-row default focus restores cleanly.
    .hudInputHandler { coord in
      TroubleshootConfirmHandler(coordinator: coord)
    }
  }

  private var deviceGroup: some View {
    VStack(spacing: 8) {
      categoryChip
      titlePanel
    }
  }

  private var actionGroup: some View {
    VStack(spacing: 8) {
      confirmPill
      rejectPill
    }
  }

  private var categoryChip: some View {
    Text((product.category ?? "Device").uppercased())
      .font(.inter(.bold, size: 10))
      .tracking(1.2)
      .foregroundStyle(Color.black.opacity(0.85))
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(
        Capsule().fill(Color(red: 1.0, green: 0.76, blue: 0.11))
      )
  }

  private var titlePanel: some View {
    VStack(spacing: 4) {
      Text(product.productName)
        .font(.inter(.medium, size: 18))
        .foregroundStyle(Color.white.opacity(0.96))
        .multilineTextAlignment(.center)
        .lineLimit(2)
      Text("\(product.confidence) confidence")
        .font(.inter(.medium, size: 10))
        .tracking(1.0)
        .foregroundStyle(Color.white.opacity(0.7))
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 14)
    .padding(.vertical, 14)
    .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
  }

  private var confirmPill: some View {
    // Forward-path action — leading checkmark + text signals "primary"
    // (no permanent yellow outline; the hover-ring color was competing
    // with the focus signal). Default focus on appear lands the
    // unified yellow ring here, so the "this is the recommended next
    // action" cue is already there without extra decoration.
    HStack(spacing: 8) {
      Image(systemName: "checkmark")
        .font(.system(size: 13, weight: .semibold))
      Text("That's it")
        .font(.inter(.medium, size: 14))
    }
    .foregroundStyle(Color.white.opacity(0.96))
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .rayBanHUDPanel(shape: .capsule)
    .hoverSelectable(.confirmIdentification, shape: .capsule, onConfirm: onConfirm)
  }

  private var rejectPill: some View {
    // Secondary path — leading `arrow.clockwise` redo glyph mirrors
    // the rediagnose pills on the Resolved / NoSolution pages so
    // "go back and re-do the previous phase" reads the same wherever
    // it appears.
    HStack(spacing: 6) {
      Image(systemName: "arrow.clockwise")
        .font(.system(size: 11, weight: .semibold))
      Text("Try again")
        .font(.inter(.medium, size: 12))
    }
    .foregroundStyle(Color.white.opacity(0.7))
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
    .rayBanHUDPanel(shape: .capsule)
    .hoverSelectable(.reIdentify, shape: .capsule, onConfirm: onReject)
  }
}
