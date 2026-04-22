import MWDATCore
import SwiftUI

struct OnboardingContainerView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  let onComplete: () -> Void

  @State private var currentPage: Int = 1
  @State private var navigationDirection: NavigationDirection = .forward

  private let totalPages = 8

  enum NavigationDirection {
    case forward
    case backward
  }

  var body: some View {
    ZStack {
      Color.backgroundPrimary.ignoresSafeArea()

      VStack(spacing: 0) {
        OnboardingTopBar(
          currentStep: currentPage,
          totalSteps: totalPages,
          onBack: currentPage > 1 ? goBack : nil,
          onSkip: finish
        )

        ZStack {
          pageContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
      }
    }
    .preferredColorScheme(.dark)
  }

  @ViewBuilder
  private var pageContent: some View {
    Group {
      if currentPage == 1 {
        OnboardingWelcomeView(onNext: advance)
          .transition(pageTransition)
          .zIndex(1)
      } else if currentPage == 2 {
        OnboardingFlowStoryView(onNext: advance)
          .transition(pageTransition)
          .zIndex(2)
      } else if currentPage == 3 {
        OnboardingExpertView(onNext: advance)
          .transition(pageTransition)
          .zIndex(3)
      } else if currentPage == 4 {
        OnboardingCoachingStyleView(onNext: advance)
          .transition(pageTransition)
          .zIndex(4)
      } else if currentPage == 5 {
        OnboardingTroubleshootView(onNext: advance)
          .transition(pageTransition)
          .zIndex(5)
      } else if currentPage == 6 {
        OnboardingVoiceView(onNext: advance)
          .transition(pageTransition)
          .zIndex(6)
      } else if currentPage == 7 {
        OnboardingGlassesView(wearablesVM: wearablesVM, onNext: advance)
          .transition(pageTransition)
          .zIndex(7)
      } else if currentPage == 8 {
        OnboardingControlsView(onFinish: finish)
          .transition(pageTransition)
          .zIndex(8)
      }
    }
    .animation(.easeInOut(duration: 0.35), value: currentPage)
  }

  private var pageTransition: AnyTransition {
    .asymmetric(
      insertion: .move(edge: navigationDirection == .forward ? .trailing : .leading),
      removal: .move(edge: navigationDirection == .forward ? .leading : .trailing)
    )
  }

  private func advance() {
    guard currentPage < totalPages else {
      finish()
      return
    }
    navigationDirection = .forward
    currentPage += 1
  }

  private func goBack() {
    guard currentPage > 1 else { return }
    navigationDirection = .backward
    currentPage -= 1
  }

  private func finish() {
    UserDefaults.standard.set(true, forKey: OnboardingContainerView.completionKey)
    onComplete()
  }

  static let completionKey = "retraceOnboardingCompleted"
}
