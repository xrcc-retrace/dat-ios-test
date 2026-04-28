import MWDATCore
import SwiftUI

enum AppMode {
  case expert
  case learner
  case troubleshoot
}

struct ModeSelectionView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @State private var selectedMode: AppMode?

  private let workflows: [LandingWorkflow] = [
    .init(
      title: "Expert Mode",
      subtitle: "Record a workflow for others",
      icon: "video.fill",
      mode: .expert
    ),
    .init(
      title: "Learner Mode",
      subtitle: "Learn workflows with AI",
      icon: "person.wave.2.fill",
      mode: .learner
    ),
    .init(
      title: "Troubleshoot",
      subtitle: "Diagnose a problem and fix",
      icon: "stethoscope",
      mode: .troubleshoot
    ),
  ]

  var body: some View {
    ZStack {
      // Persistent backdrop so no edge reveals system white during transitions.
      Color.backgroundPrimary.ignoresSafeArea()

      // Base layer: the mode selector is always rendered. It stays visible
      // behind the tab view as the tab view slides in/out from the right.
      modeSelectorScreen

      // Overlay layer: the selected mode's tab view slides in from the
      // trailing edge, covering the mode selector. On exit it slides back
      // out, revealing the mode selector already in place (no blink).
      if let mode = selectedMode {
        selectedModeView(for: mode)
          .transition(.move(edge: .trailing))
          .zIndex(1)
      }
    }
    .animation(.easeInOut(duration: 0.35), value: selectedMode)
    .tint(.textPrimary)
  }

  @ViewBuilder
  private func selectedModeView(for mode: AppMode) -> some View {
    let dismiss = { selectedMode = nil }
    switch mode {
    case .expert:
      ExpertTabView(wearables: wearables, wearablesVM: wearablesVM, onExit: dismiss)
    case .learner:
      LearnerTabView(wearables: wearables, wearablesVM: wearablesVM, onExit: dismiss)
    case .troubleshoot:
      // The intro picker chooses transport (glasses vs iPhone) before the
      // diagnostic session opens — same pattern as the coaching flow.
      TroubleshootIntroView(
        wearables: wearables,
        wearablesVM: wearablesVM,
        serverBaseURL: ServerEndpoint.shared.resolvedBaseURL,
        onExit: dismiss
      )
    }
  }

  private var modeSelectorScreen: some View {
    NavigationStack {
      RetraceScreen {
        ZStack {
          EntryBackdropView()

          ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.section) {
              heroBlock
                .padding(.top, Spacing.section + 100)

              workflowCards
                .padding(.top, Spacing.jumbo)

              Spacer(minLength: Spacing.section)

              versionFooter
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.bottom, Spacing.jumbo)
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerRelativeFrame(.vertical, alignment: .top)
          }
          .scrollBounceBehavior(.always, axes: .vertical)
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Image("RetraceWordmark")
            .resizable()
            .scaledToFit()
            .frame(width: 168, height: 28)
            .accessibilityLabel("Retrace")
        }
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink {
            ServerSettingsView(wearablesVM: wearablesVM)
          } label: {
            Image(systemName: "gearshape")
              .foregroundColor(.textPrimary)
          }
          .accessibilityLabel("Settings")
        }
      }
      .toolbarBackground(.hidden, for: .navigationBar)
    }
  }
}

extension AppMode: Hashable {}

private extension ModeSelectionView {
  var heroBlock: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      Text(greeting)
        .font(.inter(.regular, size: 24))
        .foregroundColor(.textSecondary.opacity(0.7))

      Text("What are we working on today?")
        .font(.retraceFace(.semibold, size: 28))
        .foregroundColor(.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  var workflowCards: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      ForEach(workflows) { workflow in
        ModeCard(
          icon: workflow.icon,
          title: workflow.title,
          subtitle: workflow.subtitle,
          isEnabled: true
        ) {
          selectedMode = workflow.mode
        }
      }
    }
  }

  var versionFooter: some View {
    Text("Retrace v1.0")
      .font(.system(size: 11, weight: .regular))
      .foregroundColor(.textSecondary.opacity(0.45))
      .tracking(0.4)
      .frame(maxWidth: .infinity, alignment: .center)
  }

  var greeting: String {
    let hour = Calendar.current.component(.hour, from: Date())
    switch hour {
    case 5..<12:
      return "Good morning!"
    case 12..<18:
      return "Good afternoon!"
    default:
      return "Good evening!"
    }
  }
}

private struct LandingWorkflow: Identifiable {
  let title: String
  let subtitle: String
  let icon: String
  let mode: AppMode

  var id: AppMode { mode }
}

private struct EntryBackdropView: View {
  // Tune these to reshape the diamond motion. Separation fractions are
  // expressed as a fraction of motifSize: 0 = fully overlapping diamonds,
  // 1 = fully apart.
  private let baseSeparationFraction: CGFloat = 0.0
  private let maxSeparationFraction: CGFloat = 0.75
  private let animationSpeed: Float = 0.8
  private let verticalOffset: CGFloat = 120

  // Shader visual constants — kept here so the shader argument list reads
  // declaratively rather than as a stack of bare floats.
  private let opacity: Float = 0.96
  private let pixelScale: Float = 1.0

  // Anchor for relative time. Using timeIntervalSinceReferenceDate would
  // overflow Float precision (~7.7e8) and freeze the animation. @State so
  // the anchor survives parent re-renders (tab push/pop) — otherwise
  // elapsed snaps back to 0 each time and the shader jitters.
  @State private var startDate = Date()

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
      GeometryReader { proxy in
        let size = proxy.size
        let motifSize = max(min(size.width * 0.84, size.height * 0.44), 280)
        let center = CGPoint(x: size.width * 0.42, y: size.height * 0.22 + verticalOffset)
        let elapsed = Float(context.date.timeIntervalSince(startDate))

        Rectangle()
          .fill(Color.backgroundPrimary)
          .colorEffect(
            Shader(
              function: .init(library: .default, name: "diamondLogoDither"),
              arguments: [
                .float2(Float(size.width), Float(size.height)),
                .float2(Float(center.x), Float(center.y)),
                .float(Float(motifSize)),
                .float(Float(motifSize * baseSeparationFraction)),
                .float(Float(motifSize * maxSeparationFraction)),
                .float(elapsed),
                .float(animationSpeed),
                .float(opacity),
                .float(pixelScale),
              ]
            )
          )
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .ignoresSafeArea()
  }
}
