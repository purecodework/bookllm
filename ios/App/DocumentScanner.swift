import SwiftUI
import VisionKit
import UIKit
import TranslationCore

struct DocumentScanner: UIViewControllerRepresentable {
    let cancelled: () -> Void
    let completed: (Result<URL, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(cancelled: cancelled, completed: completed) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completed: (Result<URL, Error>) -> Void
        let cancelled: () -> Void
        init(cancelled: @escaping () -> Void, completed: @escaping (Result<URL, Error>) -> Void) { self.cancelled = cancelled; self.completed = completed }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { cancelled() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { completed(.failure(error)) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            do {
                guard scan.pageCount > 0, scan.pageCount <= 100 else { throw TranslationError.message("一次扫描最多 100 页，可按章节分批扫描。") }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("扫描文稿-\(UUID().uuidString.prefix(8)).pdf")
                let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
                try renderer.writePDF(to: url) { context in
                    for index in 0..<scan.pageCount {
                        autoreleasepool {
                            let original = scan.imageOfPage(at: index)
                            let scale = min(1, 2500 / max(original.size.width, original.size.height))
                            let size = CGSize(width: original.size.width * scale, height: original.size.height * scale)
                            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in original.draw(in: CGRect(origin: .zero, size: size)) }
                            let compressed = image.jpegData(compressionQuality: 0.85).flatMap { UIImage(data: $0) } ?? image
                            let height = 595 * size.height / max(1, size.width)
                            let bounds = CGRect(x: 0, y: 0, width: 595, height: height)
                            context.beginPage(withBounds: bounds, pageInfo: [:]); compressed.draw(in: bounds)
                        }
                    }
                }
                completed(.success(url))
            } catch { completed(.failure(error)) }
        }
    }
}
