import UIKit

final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, UIImage>

    private init(countLimit: Int = 300) {
        cache = NSCache<NSString, UIImage>()
        cache.countLimit = countLimit
    }

    func image(for path: String) -> UIImage? {
        cache.object(forKey: path as NSString)
    }

    func setImage(_ image: UIImage, for path: String) {
        cache.setObject(image, forKey: path as NSString)
    }
}
