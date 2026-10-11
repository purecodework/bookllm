import XCTest
import SwiftUI
import TranslationCore
@testable import BookLLM

final class UXLayoutTests: XCTestCase {
    @MainActor func testNarrowAndLargestTypeLayouts() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let studio = StudioStore(storageURL: folder.appendingPathComponent("studio.json"))
        var job = BookJob(title: "一份需要完整显示的长文稿名称", source: "Elizabeth opened a letter.", format: "TXT")
        job.terms = [.init(source: "Elizabeth", target: "伊丽莎白")]; job.replan(); studio.jobs = [job]
        let drafts = PasteDraftCoordinator(storageURL: folder.appendingPathComponent("paste.json"))
        drafts.open(); drafts.setText("A letter arrived.\n\nA second paragraph.")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let views: [(String, AnyView)] = [
            ("configuration", AnyView(NavigationStack { JobView(id: job.id) })),
            ("paste", AnyView(PasteView())),
            ("name", AnyView(NameEditSheet(bookID: job.id, term: job.terms[0])))
        ]
        for (width, type, suffix) in [(320, DynamicTypeSize.large, "default"), (320, DynamicTypeSize.accessibility5, "largest"), (768, DynamicTypeSize.accessibility3, "ipad-type")] {
            for (name, view) in views {
                let root = view.environment(studio).environment(drafts).environment(ImportCoordinator(rootURL: folder.appendingPathComponent("imports")))
                    .environment(CloudAccount()).environment(PurchaseStore()).environment(\.dynamicTypeSize, type).preferredColorScheme(.light).tint(Ink.accent)
                let window = UIWindow(windowScene: scene), host = UIHostingController(rootView: root)
                window.rootViewController = host; window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
                window.makeKeyAndVisible(); host.view.frame = window.bounds; host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
                    XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
                }
                let screenshot = XCTAttachment(image: image)
                screenshot.name = "ux-layout-\(name)-\(width)-\(suffix)"; screenshot.lifetime = .keepAlways; add(screenshot)
                window.isHidden = true; previous?.makeKeyAndVisible()
            }
        }
    }
}
