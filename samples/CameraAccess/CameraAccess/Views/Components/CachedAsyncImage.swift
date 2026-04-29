import SwiftUI
import UIKit

/// Drop-in replacement for `AsyncImage` that keeps decoded `UIImage`s alive
/// across view re-mounts. Plain `AsyncImage` re-fetches and re-decodes the
/// PNG every time the host view appears (no decoded-bitmap memory cache, no
/// in-flight dedup), which is what produces the visible icon flash on tab
/// switches in the Discover/Library lists. URLCache still handles the
/// transport bytes — this layer just holds the decoded bitmap.
struct CachedAsyncImage<Content: View>: View {
  let url: URL?
  let content: (AsyncImagePhase) -> Content

  @State private var phase: AsyncImagePhase

  init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
    self.url = url
    self.content = content
    // Synchronous cache check at @State init kills the .empty flash on
    // re-mount. The first body render already sees .success when the bitmap
    // is in memory.
    if let url, let img = ImageMemoryCache.shared.cachedImage(for: url) {
      self._phase = State(initialValue: .success(Image(uiImage: img)))
    } else {
      self._phase = State(initialValue: .empty)
    }
  }

  var body: some View {
    content(phase)
      .task(id: url) {
        guard let url else {
          phase = .empty
          return
        }
        if let cached = ImageMemoryCache.shared.cachedImage(for: url) {
          if case .success = phase {} else {
            phase = .success(Image(uiImage: cached))
          }
          return
        }
        // URL changed mid-mount and the new one isn't cached — clear stale
        // success so the caller's .empty branch can render its placeholder.
        if case .success = phase { phase = .empty }
        if let img = await ImageMemoryCache.shared.image(for: url) {
          phase = .success(Image(uiImage: img))
        } else {
          phase = .failure(URLError(.cannotDecodeContentData))
        }
      }
  }
}

/// Process-wide decoded-image cache. Mirrors `VideoThumbnailCache`:
/// `NSCache` for the actual storage, in-flight task dedup so two views
/// requesting the same URL share a single fetch+decode.
final class ImageMemoryCache: @unchecked Sendable {
  static let shared = ImageMemoryCache()

  private let cache: NSCache<NSURL, UIImage>
  private let lock = NSLock()
  private var inflight: [URL: Task<UIImage?, Never>] = [:]

  private init() {
    cache = NSCache<NSURL, UIImage>()
    cache.countLimit = 256
    // ~32 MB of decoded bitmap budget. NSCache prunes itself under memory
    // pressure independent of countLimit.
    cache.totalCostLimit = 32 * 1024 * 1024
  }

  /// Thread-safe synchronous lookup. NSCache's `object(forKey:)` is
  /// documented as safe to call from any thread.
  func cachedImage(for url: URL) -> UIImage? {
    cache.object(forKey: url as NSURL)
  }

  /// Async lookup with in-flight dedup. Hits NSCache → joins an existing
  /// task → starts a new fetch.
  func image(for url: URL) async -> UIImage? {
    if let hit = cachedImage(for: url) { return hit }

    lock.lock()
    if let existing = inflight[url] {
      lock.unlock()
      return await existing.value
    }
    let task = Task<UIImage?, Never> { await Self.fetch(url: url) }
    inflight[url] = task
    lock.unlock()

    let img = await task.value

    lock.lock()
    inflight[url] = nil
    lock.unlock()

    if let img {
      let cost = Int(img.size.width * img.size.height * 4)
      cache.setObject(img, forKey: url as NSURL, cost: cost)
    }
    return img
  }

  private static func fetch(url: URL) async -> UIImage? {
    var req = URLRequest(url: url)
    // URLCache holds the raw bytes; this policy says use anything cached
    // even if `Cache-Control: max-age` has expired. Pull-to-refresh paths
    // can opt out by going through their own URLRequest.
    req.cachePolicy = .returnCacheDataElseLoad
    do {
      let (data, _) = try await URLSession.shared.data(for: req)
      return UIImage(data: data)
    } catch {
      return nil
    }
  }
}
