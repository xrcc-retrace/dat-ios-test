import MWDATCore
import SwiftUI

enum AppMode {
  case expert
  case learner
}

struct ModeSelectionView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @State private var selectedMode: AppMode?

  var body: some View {
    NavigationStack {
      ZStack {
        Color.black.edgesIgnoringSafeArea(.all)

        VStack(spacing: 32) {
          Spacer()

          Text("Retrace")
            .font(.system(size: 36, weight: .bold))
            .foregroundColor(.white)

          Text("Record an expert once.\nCoach every learner forever.")
            .font(.system(size: 16))
            .foregroundColor(.gray)
            .multilineTextAlignment(.center)

          Spacer()

          // Expert Mode
          ModeCard(
            icon: "video.fill",
            title: "Expert Mode",
            subtitle: "Record a procedure for learners",
            isEnabled: true
          ) {
            selectedMode = .expert
          }

          // Learner Mode
          ModeCard(
            icon: "headphones",
            title: "Learner Mode",
            subtitle: "Coming Soon",
            isEnabled: false
          ) {}

          Spacer()
        }
        .padding(.horizontal, 24)
      }
      .navigationDestination(item: $selectedMode) { mode in
        switch mode {
        case .expert:
          StreamSessionView(wearables: wearables, wearablesVM: wearablesVM)
        case .learner:
          EmptyView()
        }
      }
    }
  }
}

extension AppMode: Hashable {}

struct ModeCard: View {
  let icon: String
  let title: String
  let subtitle: String
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 16) {
        Image(systemName: icon)
          .font(.system(size: 28))
          .foregroundColor(isEnabled ? .white : .gray)
          .frame(width: 48, height: 48)
          .background(isEnabled ? Color.appPrimary : Color(.systemGray4))
          .cornerRadius(12)

        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(isEnabled ? .white : .gray)
          Text(subtitle)
            .font(.system(size: 14))
            .foregroundColor(isEnabled ? .gray : .gray.opacity(0.6))
        }

        Spacer()

        if isEnabled {
          Image(systemName: "chevron.right")
            .foregroundColor(.gray)
        }
      }
      .padding(20)
      .background(Color(.systemGray6).opacity(0.15))
      .cornerRadius(16)
      .overlay(
        RoundedRectangle(cornerRadius: 16)
          .stroke(isEnabled ? Color.appPrimary.opacity(0.3) : Color.clear, lineWidth: 1)
      )
    }
    .disabled(!isEnabled)
  }
}
