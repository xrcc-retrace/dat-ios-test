import AVFoundation
import SwiftUI
import UIKit

actor VideoThumbnailCache {
  static let shared = VideoThumbnailCache()

  private let cache: NSCache<NSURL, UIImage> = {
    let c = NSCache<NSURL, UIImage>()
    c.countLimit = 64
    return c
  }()
  private var inflight: [URL: Task<UIImage?, Never>] = [:]

  func image(for url: URL) async -> UIImage? {
    if let hit = cache.object(forKey: url as NSURL) { return hit }
    if let t = inflight[url] { return await t.value }
    let t = Task<UIImage?, Never> { await Self.generate(url: url) }
    inflight[url] = t
    let img = await t.value
    inflight[url] = nil
    if let img { cache.setObject(img, forKey: url as NSURL) }
    return img
  }

  private static func generate(url: URL) async -> UIImage? {
    let asset = AVURLAsset(url: url)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    gen.maximumSize = CGSize(width: 720, height: 720)
    do {
      let (cg, _) = try await gen.image(at: .zero)
      return UIImage(cgImage: cg)
    } catch {
      return nil
    }
  }
}

struct VideoThumbnailView: View {
  let url: URL
  var cornerRadius: CGFloat = 0
  @State private var image: UIImage?

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.surfaceRaised)
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    .task(id: url) {
      image = await VideoThumbnailCache.shared.image(for: url)
    }
  }
}
