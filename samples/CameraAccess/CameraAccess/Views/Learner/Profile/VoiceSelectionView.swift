import SwiftUI

struct VoiceSelectionView: View {
  @AppStorage("geminiVoice") private var selectedVoice = "Puck"
  @StateObject private var player = VoicePreviewPlayer()
  @State private var voices: [VoiceOption] = VoiceSelectionView.fallbackVoices

  private var serverBaseURL: String {
    UserDefaults.standard.string(forKey: "serverBaseURL") ?? "http://192.168.1.100:8000"
  }

  var body: some View {
    RetraceScreen {

      ScrollView {
        VStack(spacing: Spacing.lg) {
          ForEach(voices) { voice in
            voiceRow(voice)
          }
        }
        .padding(Spacing.screenPadding)
      }
    }
    .navigationTitle("AI Voice")
    .navigationBarTitleDisplayMode(.inline)
    .retraceNavBar()
    .task { await fetchVoices() }
    .onDisappear { player.stop() }
  }

  // MARK: - Voice Row

  @ViewBuilder
  private func voiceRow(_ voice: VoiceOption) -> some View {
    let isSelected = selectedVoice == voice.name
    let isPlaying = player.currentlyPlaying == voice.name
    let isLoading = player.isLoading && player.currentlyPlaying == voice.name

    Button {
      selectedVoice = voice.name
    } label: {
      HStack(spacing: Spacing.xl) {
        // Voice info
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(voice.name)
            .font(.retraceFace(.medium, size: 17))
            .foregroundColor(.textPrimary)
          Text(voice.description)
            .font(.retraceCaption1)
            .foregroundColor(.textSecondary)
        }

        Spacer()

        // Preview button
        Button {
          if let url = previewURL(for: voice) {
            player.play(voiceName: voice.name, url: url)
          }
        } label: {
          Group {
            if isLoading {
              ProgressView()
                .tint(.textPrimary)
            } else {
              Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.textPrimary)
            }
          }
          .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)

        // Selection indicator
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

  // MARK: - Helpers

  private func previewURL(for voice: VoiceOption) -> URL? {
    URL(string: "\(serverBaseURL)\(voice.previewUrl)")
  }

  private func fetchVoices() async {
    guard let url = URL(string: "\(serverBaseURL)/api/learner/voices") else { return }
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let fetched = try decoder.decode([VoiceOption].self, from: data)
      if !fetched.isEmpty {
        voices = fetched
      }
    } catch {
      // Keep fallback list
    }
  }

  // MARK: - Fallback

  static let fallbackVoices: [VoiceOption] = [
    VoiceOption(name: "Puck", description: "Upbeat and energetic", previewUrl: "/static/voice_previews/Puck.wav"),
    VoiceOption(name: "Charon", description: "Calm and informative", previewUrl: "/static/voice_previews/Charon.wav"),
    VoiceOption(name: "Kore", description: "Clear and firm", previewUrl: "/static/voice_previews/Kore.wav"),
    VoiceOption(name: "Fenrir", description: "Warm and encouraging", previewUrl: "/static/voice_previews/Fenrir.wav"),
    VoiceOption(name: "Aoede", description: "Bright and expressive", previewUrl: "/static/voice_previews/Aoede.wav"),
    VoiceOption(name: "Zephyr", description: "Bright and breezy", previewUrl: "/static/voice_previews/Zephyr.wav"),
    VoiceOption(name: "Enceladus", description: "Soft and breathy", previewUrl: "/static/voice_previews/Enceladus.wav"),
    VoiceOption(name: "Leda", description: "Steady and neutral", previewUrl: "/static/voice_previews/Leda.wav"),
  ]
}
