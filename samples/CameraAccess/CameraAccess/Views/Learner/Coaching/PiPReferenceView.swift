import AVKit
import SwiftUI

struct PiPReferenceView: View {
  let url: URL
  @State private var player: AVPlayer?
  @State private var offset: CGSize = .zero
  @State private var lastOffset: CGSize = .zero

  var body: some View {
    VStack {
      HStack {
        Spacer()

        Group {
          if let player {
            VideoPlayer(player: player)
          } else {
            ZStack {
              VideoThumbnailView(url: url)
              Button {
                let p = AVPlayer(url: url)
                player = p
                p.play()
              } label: {
                Image(systemName: "play.circle.fill")
                  .font(.system(size: 24))
                  .foregroundColor(.white.opacity(0.8))
              }
            }
          }
        }
        .frame(width: 160, height: 120)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.5), radius: 8)
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .offset(offset)
        .gesture(
          DragGesture()
            .onChanged { value in
              offset = CGSize(
                width: lastOffset.width + value.translation.width,
                height: lastOffset.height + value.translation.height
              )
            }
            .onEnded { _ in
              lastOffset = offset
            }
        )
      }
      .padding(.trailing, 16)
      .padding(.top, 60)

      Spacer()
    }
  }
}
