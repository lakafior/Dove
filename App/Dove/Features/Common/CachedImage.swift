import DoveKit
import SwiftUI
import UIKit

/// Artwork from `ImageCache` (on disk across launches) with decoded images kept in memory, so posters neither
/// download again on launch nor flicker when a grid scrolls them back in.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder
    /// Seeded once from memory so a known poster shows on the first frame; `task(id:)` follows URL changes.
    @State private var image: UIImage?

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap(DecodedImages.shared.image(for:)))
    }

    var body: some View {
        // Clear takes exactly the offered size; the filled image cannot push the frame out.
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholder()
                }
            }
            .clipped()
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { image = nil; return }
        if let known = DecodedImages.shared.image(for: url) {
            image = known
            return
        }
        image = nil
        guard let data = try? await ImageCache.shared.data(for: url),
              let decoded = await UIImage(data: data)?.byPreparingForDisplay()
        else { return }
        DecodedImages.shared.insert(decoded, for: url)
        withAnimation(.easeOut(duration: 0.15)) { image = decoded }
    }
}

/// Decoded images by URL. `NSCache` is thread-safe and drops entries under memory pressure.
final class DecodedImages: @unchecked Sendable {
    static let shared = DecodedImages()
    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 120 * 1024 * 1024
        return cache
    }()

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        cache.setObject(image, forKey: url as NSURL, cost: Int(pixels) * 4)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
