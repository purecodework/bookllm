import Foundation
import UIKit
import TranslationCore

@MainActor enum CoverStorage {
    private static let directory = URL.applicationSupportDirectory.appendingPathComponent("BookLLM/covers", isDirectory: true)
    private static let cache: NSCache<NSString, UIImage> = {
        let value = NSCache<NSString, UIImage>(); value.totalCostLimit = 48 * 1024 * 1024; return value
    }()
    private static func url(for key: String?) -> URL? {
        guard let key, UUID(uuidString: key) != nil else { return nil }
        return directory.appendingPathComponent(key).appendingPathExtension("cover")
    }
    static func save(_ data: Data) throws -> String {
        guard data.count <= 12 * 1024 * 1024, UIImage(data: data) != nil else { throw TranslationError.message("封面无法读取，请重新导出文件。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = UUID().uuidString
        try data.write(to: url(for: key)!, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return key
    }
    static func image(for key: String?) -> UIImage? {
        guard let key, let url = url(for: key) else { return nil }
        if let image = cache.object(forKey: key as NSString) { return image }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }
    static func data(for key: String?) -> Data? {
        guard let url = url(for: key), let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 12 * 1024 * 1024 else { return nil }
        return try? Data(contentsOf: url)
    }
}
