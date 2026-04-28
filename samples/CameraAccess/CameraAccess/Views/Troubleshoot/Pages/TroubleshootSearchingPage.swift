import SwiftUI

/// Two-stage search lens. Active when `phase == .resolving` and
/// `resolution == nil`. Stage is derived from the VM's `searchStage`
/// property (driven by which tool call is in flight on the base):
///
/// - `.searchingLibrary` → "Searching your library" + spinner
/// - `.searchingWeb`     → "Searching the web" + animated Google graphic
///
/// Stage transitions use the asymmetric inline transition from the
/// design system. The web-search graphic is Core-Animation-driven via a
/// single `withAnimation(.linear(...)).repeatForever(...)` over a state
/// flip; no polled timer ticks per the design doc's no-poll rule.
///
/// Layout mirrors coaching: phase indicator top -> main card middle
/// (with the spinner / web graphic as accessory) -> bottom audio row.
struct TroubleshootSearchingPage: RayBanHUDView {
  @ObservedObject var viewModel: DiagnosticSessionViewModel
  /// Focus-engine `.dismiss` → trigger the end-diagnostic confirmation
  /// alert. Owned by `TroubleshootSessionView`.
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Spacer(minLength: 0)

      DiagnosticPhaseLensBar(phase: viewModel.phase)
      stageCard
        .transition(.asymmetric(
          insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)),
          removal: .opacity
        ))
      bottomActionRow

      Spacer(minLength: 0)
    }
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, RayBanHUDLayoutTokens.contentPadding)
    .animation(.spring(response: 0.32, dampingFraction: 0.85), value: viewModel.searchStage)
    // Passive page — only behavior is the dismiss path.
    .hudInputHandler { coord in
      TroubleshootPageHandler(
        coordinator: coord,
        onSetMuted: { muted in viewModel.setMuted(muted) },
        onDismiss: onDismiss
      )
    }
  }

  private var bottomActionRow: some View {
    RayBanHUDBottomAudioActionRow(
      isMuted: viewModel.isMuted,
      aiPeak: viewModel.aiOutputPeak,
      userPeak: viewModel.userInputPeak,
      muteControl: .diagnosticToggleMute,
      exitControl: .diagnosticExit,
      onToggleMute: { viewModel.toggleMute() },
      onExit: onDismiss
    )
  }

  @ViewBuilder
  private var stageCard: some View {
    switch viewModel.searchStage {
    case .searchingWeb:
      TroubleshootStageHeaderCard(
        stage: .findFix,
        title: "Searching the web",
        bodyText: "Reddit, iFixit, manuals — fetching sources."
      ) {
        WebSearchGraphic()
          .frame(height: 56)
          .frame(maxWidth: .infinity)
      }
      .id("searchingWeb")
    default:
      // Default to library-searching whenever phase is .resolving and
      // there's no in-flight tool name yet (tiny gap between dispatch
      // and the @Published flip).
      TroubleshootStageHeaderCard(
        stage: .findFix,
        title: "Searching your library",
        bodyText: "Checking your saved procedures."
      ) {
        HStack {
          Spacer()
          ProgressView()
            .tint(Color.white.opacity(0.85))
            .controlSize(.regular)
          Spacer()
        }
      }
      .id("searchingLibrary")
    }
  }
}

// MARK: - Animated Google-search graphic

/// "G" mark + dotted travel-line that loops while a web search is in
/// flight. Built off a single linear-repeat-forever animation over a
/// `phase` state value — no `Timer.publish`, no per-tick `@State`
/// writes (per `DESIGN.md`'s no-poll rule).
private struct WebSearchGraphic: View {
  @State private var phase: CGFloat = 0

  var body: some View {
    HStack(spacing: 12) {
      googleMark
      travelLine
        .frame(maxWidth: .infinity)
    }
    .onAppear {
      withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
        phase = 1
      }
    }
  }

  private var googleMark: some View {
    ZStack {
      Circle()
        .fill(Color.white.opacity(0.95))
        .frame(width: 32, height: 32)
      Text("G")
        .font(.system(size: 16, weight: .bold, design: .default))
        .foregroundStyle(Color(red: 0.26, green: 0.52, blue: 0.96))
    }
  }

  private var travelLine: some View {
    GeometryReader { geom in
      let width = geom.size.width
      let dotCount = 9
      let spacing = width / CGFloat(dotCount)
      ZStack(alignment: .leading) {
        // Static dotted track.
        HStack(spacing: 0) {
          ForEach(0..<dotCount, id: \.self) { _ in
            Circle()
              .fill(Color.white.opacity(0.18))
              .frame(width: 4, height: 4)
              .frame(width: spacing, alignment: .leading)
          }
        }
        // Highlight that travels along the track.
        Circle()
          .fill(Color.white.opacity(0.95))
          .frame(width: 6, height: 6)
          .offset(x: phase * (width - 6))
      }
      .frame(height: 8)
      .frame(maxHeight: .infinity, alignment: .center)
    }
  }
}
