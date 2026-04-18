import Foundation

/// Which hardware pipeline supplies video (and, for coaching, audio) for a session.
enum CaptureTransport: Hashable, Sendable, Identifiable {
  /// Meta DAT SDK glasses via BT streaming.
  case glasses
  /// iPhone native camera + built-in mic + loudspeaker.
  case iPhone

  /// `Identifiable` conformance so SwiftUI's `sheet(item:) / fullScreenCover(item:)`
  /// can present a coaching session with the transport as the parameter —
  /// avoids the State-race where a separate `isPresented: Bool` + `transport`
  /// pair lets the cover content evaluate against a stale transport.
  var id: Self { self }
}
