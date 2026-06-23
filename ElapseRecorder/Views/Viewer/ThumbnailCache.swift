import CoreGraphics
import Foundation

/// Process-wide in-memory cache for decoded screenshot thumbnails.
///
/// `LazyVGrid` destroys off-screen cells, so without a cache every cell that scrolls
/// back into view reloads its thumbnail from disk and flashes a placeholder first —
/// which is what makes scrolling back up jank. Caching by the screenshot's stable id
/// lets a recycled cell show its image immediately. `NSCache` evicts under memory
/// pressure on its own.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, CGImage>()

    private init() {
        cache.countLimit = 500
    }

    func image(forID id: UUID) -> CGImage? {
        cache.object(forKey: id.uuidString as NSString)
    }

    func insert(_ image: CGImage, forID id: UUID) {
        cache.setObject(image, forKey: id.uuidString as NSString)
    }
}
