import SwiftUI

/// Marker protocol for every Ray-Ban lens "page."
///
/// Conformers are pure SwiftUI views laid out for a square frame. The
/// `RayBanHUDEmulator` host owns the viewport sizing, hover coordinator,
/// page-indicator strip, scrim, and the **single gesture pipeline** that
/// drives page navigation. Pages don't wire any gesture code themselves —
/// finger swipes today and MediaPipe pinch-drag tomorrow flow into the
/// same `pageIndex` binding on the emulator.
@MainActor
protocol RayBanHUDView: View {}
