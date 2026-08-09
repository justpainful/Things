import SwiftUI
import UIKit
import ThingsCore

/// Showing bytes that live on disk sealed with AES-GCM.
///
/// Loading one thumbnail is a database read, a key unwrap, a frame-by-frame decrypt and an
/// image decode. None of that belongs on the main actor, and none of it should happen twice
/// for the same tile — so it runs detached and the result is cached.
///
/// **Never glass.** Media is the subject; glass over it steals from it.

final class DecryptedImageCache: @unchecked Sendable {

    static let shared = DecryptedImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var backgroundObserver: NSObjectProtocol?

    private init() {
        cache.countLimit = 240
        // Decrypted pixels do not outlive the foreground session. Locking normally follows
        // backgrounding, and a cache that survived it would keep a locked library's photos
        // in memory — which is exactly the thing the app promises it does not do.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [cache] _ in
            cache.removeAllObjects()
        }
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    static func key(hash: String, maximumSide: CGFloat?, scale: CGFloat) -> String {
        guard let maximumSide else { return "\(hash)@full" }
        return "\(hash)@\(Int(maximumSide * scale))"
    }
}

/// Renders the image behind an `object_hash`, or nothing at all.
///
/// Renders `Color.clear` until it has pixels, so a caller can simply place it over its own
/// placeholder rather than threading a loaded/not-loaded flag back out.
struct DecryptedImageView: View {

    let objectHash: String
    let library: Library
    /// Longest edge to decode to, in points, or `nil` for the full image.
    var maximumSide: CGFloat?
    var contentMode: ContentMode = .fill

    @Environment(\.displayScale) private var displayScale

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .accessibilityHidden(true)
            } else {
                Color.clear
            }
        }
        .task(id: objectHash) { await load() }
    }

    private func load() async {
        let key = DecryptedImageCache.key(hash: objectHash, maximumSide: maximumSide, scale: displayScale)
        if let cached = DecryptedImageCache.shared.image(forKey: key) {
            image = cached
            return
        }
        // The hash changed under this view, so whatever is on screen belongs to something
        // else. Clearing beats showing one Thing's photo in another's tile.
        image = nil

        let hash = objectHash
        let library = self.library
        let pixelSide = maximumSide.map { $0 * displayScale }

        let loaded = await Task.detached(priority: .utility) { () async -> UIImage? in
            let data: Data
            do {
                data = try library.read { db in try library.objects.load(db, hash: hash) }
            } catch {
                // A missing object is the ordinary "chose not to download it" case, not an
                // error worth a banner. The caller's placeholder already says so.
                return nil
            }
            guard let full = UIImage(data: data) else { return nil }
            guard let pixelSide else { return full }
            return full.preparingThumbnail(of: CGSize(width: pixelSide, height: pixelSide)) ?? full
        }.value

        guard let loaded else { return }
        DecryptedImageCache.shared.insert(loaded, forKey: key)
        image = loaded
    }
}
