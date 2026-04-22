import SwiftUI

struct OnboardingVoiceView: View {
  let onNext: () -> Void

  @AppStorage("geminiVoice") private var selectedVoice = "Puck"
  @StateObject private var player = VoicePreviewPlayer()
  @State private var voices: [VoiceOption] = VoiceSelectionView.fallbackVoices
  @State private var serverAvailable: Bool = true

  private var serverBaseURL: String {
    ServerEndpoint.shared.resolvedBaseURL
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        Text("Pick your AI voice.")
          .font(.retraceTitle1)
          .foregroundColor(.textPrimary)

        Text("You'll hear this voice during coaching. Tap to preview.")
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Spacing.screenPadding)
      .padding(.top, Spacing.lg)
      .padding(.bottom, Spacing.section)

      ScrollView(showsIndicators: false) {
        VStack(spacing: Spacing.lg) {
          ForEach(voices) { voice in
            voiceRow(voice)
          }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.bottom, Spacing.xl)
      }

      CustomButton(
        title: "Next",
        style: .primary,
        isDisabled: false,
        action: onNext
      )
      .padding(.horizontal, Spacing.screenPadding)
      .padding(.bottom, Spacing.xl)
    }
    .task { await fetchVoices() }
    .onDisappear { player.stop() }
  }

  @ViewBuilder
  private func voiceRow(_ voice: VoiceOption) -> some View {
    let isSelected = selectedVoice == voice.name
    let isPlaying = player.currentlyPlaying == voice.name
    let isLoading = player.isLoading && player.currentlyPlaying == voice.name

    Button {
      selectedVoice = voice.name
    } label: {
      HStack(spacing: Spacing.xl) {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(voice.name)
            .font(.retraceFace(.medium, size: 17))
            .foregroundColor(.textPrimary)
          Text(voice.description)
            .font(.retraceCaption1)
            .foregroundColor(.textSecondary)
        }

        Spacer()

        if serverAvailable {
          Button {
            if let url = previewURL(for: voice) {
              player.play(voiceName: voice.name, url: url)
            }
          } label: {
            Group {
              if isLoading {
                ProgressView().tint(.textPrimary)
              } else {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                  .font(.system(size: 26))
                  .foregroundColor(.textPrimary)
              }
            }
            .frame(width: 32, height: 32)
          }
          .buttonStyle(.plain)
        }

        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22))
          .foregroundColor(isSelected ? .textPrimary : .textTertiary)
      }
      .padding(Spacing.xl)
      .background(isSelected ? Color.surfaceRaised : Color.surfaceBase)
      .cornerRadius(Radius.md)
    }
    .buttonStyle(.plain)
  }

  private func previewURL(for voice: VoiceOption) -> URL? {
    URL(string: "\(serverBaseURL)\(voice.previewUrl)")
  }

  private func fetchVoices() async {
    guard let url = URL(string: "\(serverBaseURL)/api/learner/voices") else {
      serverAvailable = false
      return
    }
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let fetched = try decoder.decode([VoiceOption].self, from: data)
      if !fetched.isEmpty {
        voices = fetched
        serverAvailable = true
      }
    } catch {
      serverAvailable = false
    }
  }
}
