import XCTest

final class ExperienceFlowTests: XCTestCase {
    @MainActor private func launch(parallel: Bool = false, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--paper-ui-testing"] + (reset ? ["--paper-ui-reset"] : []) + (parallel ? ["--paper-ui-parallel"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["导入文稿"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor private func paste(_ app: XCUIApplication) {
        app.buttons["导入文稿"].tap()
        app.buttons["粘贴文本"].tap()
        XCTAssertTrue(app.textViews["粘贴原文"].waitForExistence(timeout: 5))
    }
    @MainActor func testPasteDraftSurvivesCloseAndRestartThenAddsOnce() {
        var app = launch()
        paste(app)
        XCTAssertTrue(app.staticTexts["原文"].exists)
        let title = app.textFields["文稿名称，可选"]
        title.tap(); title.typeText("Saved draft")
        let text = app.textViews["粘贴原文"]
        text.tap(); text.typeText("Chapter I\n\nA letter arrived in the quiet garden.")
        capture("ux-paste-software-keyboard", app)
        app.buttons["收起键盘"].tap()
        app.buttons["关闭"].tap()
        app.terminate()
        app = launch(reset: false)
        paste(app)
        XCTAssertEqual(app.textFields["文稿名称，可选"].value as? String, "Saved draft")
        XCTAssertTrue((app.textViews["粘贴原文"].value as? String)?.contains("A letter arrived") == true)
        capture("ux-paste-restored", app)
        app.buttons["添加文稿，设置翻译"].tap()
        XCTAssertTrue(app.navigationBars["翻译设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved draft"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(app.buttons.matching(identifier: "Saved draft").count, 1)
        paste(app)
        XCTAssertEqual(app.textViews["粘贴原文"].value as? String, "")
    }
    @MainActor func testDirectoryShowsUnavailableChapterAndFullScreenReturn() {
        let app = launch(parallel: true)
        app.buttons["进度"].tap()
        app.buttons["阅读已完成章节"].tap()
        XCTAssertTrue(app.buttons["返回本书进度"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["导入文稿"].isHittable)
        app.buttons["目录"].tap()
        let first = app.buttons["toc-chapter-0"]
        let second = app.buttons["toc-chapter-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists)
        XCTAssertFalse(second.isEnabled)
        capture("ux-all-chapters", app)
        app.buttons["关闭"].tap()
        app.buttons["返回本书进度"].tap()
        XCTAssertTrue(app.buttons["暂停翻译"].waitForExistence(timeout: 5))
        app.buttons["关闭本书详情"].tap()
        XCTAssertTrue(app.buttons["导入文稿"].isHittable)
    }
    @MainActor func testLibraryExportDefaultsToWholeBookAndDoesNotOpenReader() {
        let app = launch()
        app.buttons["午后的花园 的菜单"].tap()
        app.buttons["book-menu-export-paper-complete"].tap()
        XCTAssertTrue(app.navigationBars["导出与分享"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已完成 2 / 2 章"].exists)
        XCTAssertFalse(app.buttons["阅读菜单"].exists)
        capture("ux-export-whole-book", app)
        app.buttons["生成导出文件"].tap()
        XCTAssertTrue(app.staticTexts["文件已生成"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["分享或保存"].exists)
        XCTAssertTrue(app.buttons["重新生成"].exists)
        capture("ux-export-ready", app)
    }
    @MainActor func testReaderExportDefaultsToCurrentChapter() {
        let app = launch()
        app.buttons["library-read-paper-complete"].tap()
        XCTAssertTrue(app.buttons["阅读菜单"].waitForExistence(timeout: 5))
        app.buttons["阅读菜单"].tap()
        app.buttons["导出与分享"].tap()
        XCTAssertTrue(app.staticTexts["已完成 1 / 1 章"].waitForExistence(timeout: 5))
        capture("ux-export-current-chapter", app)
        app.buttons["export-scope"].tap()
        app.buttons["全书已完成内容"].tap()
        XCTAssertTrue(app.staticTexts["已完成 2 / 2 章"].waitForExistence(timeout: 5))
    }
    @MainActor func testNameEffectIsVisibleBeforeSave() {
        let app = launch()
        app.buttons["午后的花园 的菜单"].tap()
        app.buttons["译名"].tap()
        app.buttons["修改 Elizabeth 的译名"].tap()
        let note = app.staticTexts["name-effect-explanation"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(note.isHittable)
        XCTAssertTrue(note.label.contains("当前译文不会改变"))
        app.textFields["译名"].tap()
        XCTAssertTrue(app.buttons["保存"].isHittable)
        XCTAssertTrue(note.isHittable)
        capture("ux-name-effect-keyboard", app)
    }
    @MainActor func testUnavailableCloudAndUnsavedAPIEdit() {
        let app = launch()
        app.buttons["设置翻译"].tap()
        XCTAssertTrue(app.buttons["点数服务暂不可用"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["点数服务暂不可用"].isEnabled)
        app.buttons["更改使用方式与 API 设置"].tap()
        XCTAssertTrue(app.buttons["购买点数"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["购买点数"].isEnabled)
        app.buttons["买断自带 API"].tap()
        let endpoint = app.textFields["api-endpoint"]
        for _ in 0..<4 where !endpoint.isHittable { app.swipeUp() }
        XCTAssertTrue(endpoint.isHittable)
        let original = endpoint.value as? String ?? ""
        endpoint.tap()
        endpoint.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count))
        endpoint.typeText("https://example.com/v1")
        app.buttons["关闭"].tap()
        app.buttons["更改使用方式与 API 设置"].tap()
        let restored = app.textFields["api-endpoint"]
        for _ in 0..<4 where !restored.isHittable { app.swipeUp() }
        XCTAssertEqual(restored.value as? String, original)
        capture("ux-api-labeled-fields", app)
    }
    @MainActor func testModelLimitsCanBeEditedAndInvalidSavePreservesConnection() {
        let app = launch()
        app.buttons["设置翻译"].tap()
        app.buttons["更改使用方式与 API 设置"].tap()
        app.buttons["买断自带 API"].tap()
        let window = app.textFields["api-context-window"], output = app.textFields["api-maximum-output"]
        for _ in 0..<6 where !window.isHittable { app.swipeUp() }
        XCTAssertTrue(window.isHittable)
        let original = window.value as? String ?? ""
        window.tap(); window.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count)); window.typeText("1023")
        XCTAssertTrue(app.buttons["收起键盘"].waitForExistence(timeout: 3))
        capture("model-limits-number-keyboard", app)
        app.buttons["收起键盘"].tap()
        for _ in 0..<4 where !output.isHittable { app.swipeUp() }
        XCTAssertTrue(output.isHittable)
        XCTAssertEqual(output.value as? String, "8192")
        let key = app.secureTextFields["api-key"]
        for _ in 0..<4 where !key.isHittable { app.swipeUp() }
        key.tap(); key.typeText("unit-test-unsaved-key")
        app.buttons["收起键盘"].tap()
        let save = app.buttons["save-api-connection"]
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        save.tap()
        let error = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "模型上下文窗口须为")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["已保存 ✓"].exists)
        capture("model-limits-invalid-save", app)
        app.buttons["关闭"].tap()
        app.buttons["更改使用方式与 API 设置"].tap()
        let restored = app.textFields["api-context-window"]
        for _ in 0..<6 where !restored.isHittable { app.swipeUp() }
        XCTAssertEqual(restored.value as? String, original)
        capture("model-limits-restored", app)
    }
    @MainActor func testLargestTypeKeepsEditorsAndPrimaryActionsReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--paper-ui-testing", "--paper-ui-reset", "--paper-ui-largest-type"]
        app.launch()
        XCTAssertTrue(app.buttons["导入文稿"].waitForExistence(timeout: 10))
        paste(app)
        XCTAssertGreaterThan(app.staticTexts["文稿名称（可选）"].frame.height, 35)
        let title = app.textFields["文稿名称，可选"]
        XCTAssertTrue(title.isHittable)
        title.tap(); title.typeText("Large draft")
        if app.buttons["收起键盘"].exists { app.buttons["收起键盘"].tap() }
        let text = app.textViews["粘贴原文"]
        for _ in 0..<5 where !text.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(text.isHittable)
        text.tap(); text.typeText("A short manuscript.")
        XCTAssertTrue(app.buttons["添加文稿，设置翻译"].isHittable)
        capture("ux-largest-paste-editing", app)
        app.buttons["关闭"].tap()
        let menu = app.buttons["午后的花园 的菜单"]
        for _ in 0..<6 where !menu.isHittable { app.scrollViews.firstMatch.swipeUp() }
        menu.tap(); app.buttons["译名"].tap()
        app.buttons["修改 Elizabeth 的译名"].tap()
        XCTAssertTrue(app.textFields["译名"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["译名"].isHittable)
        XCTAssertTrue(app.buttons["保存"].isHittable)
        app.textFields["译名"].tap()
        XCTAssertTrue(app.buttons["保存"].isHittable)
        capture("ux-largest-name-editing", app)
    }
    @MainActor func testUsageIntroductionCanCloseAndNeverChangesUsageMode() {
        let app = launch()
        app.buttons["账户与设置"].tap()
        let intro = app.buttons["使用介绍"]
        for _ in 0..<6 where !intro.isHittable { app.swipeUp() }
        intro.tap()
        XCTAssertTrue(app.buttons["关闭使用介绍"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["先导入，再翻译。"].exists)
        capture("polish-introduction-import", app)
        app.buttons["继续"].tap()
        capture("polish-introduction-quality", app)
        app.buttons["继续"].tap()
        XCTAssertTrue(app.staticTexts["两种使用方式"].exists)
        XCTAssertFalse(app.buttons["买断自带 API"].exists)
        capture("polish-introduction-modes", app)
        app.buttons["完成介绍"].tap()
        for _ in 0..<6 where !app.buttons["按量付费"].isHittable { app.swipeDown() }
        XCTAssertTrue(app.buttons["按量付费"].isSelected)
        for _ in 0..<6 where !intro.isHittable { app.swipeUp() }
        intro.tap()
        app.buttons["关闭使用介绍"].tap()
        XCTAssertTrue(app.navigationBars["账户与设置"].exists)
    }
    @MainActor func testLargestTypeUsageIntroductionKeepsNavigationReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--paper-ui-testing", "--paper-ui-reset", "--paper-ui-largest-type"]
        app.launch()
        app.buttons["账户与设置"].tap()
        let intro = app.buttons["使用介绍"]
        for _ in 0..<10 where !intro.isHittable { app.swipeUp() }
        intro.tap()
        XCTAssertTrue(app.buttons["关闭使用介绍"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.staticTexts["先导入，再翻译。"].frame.height, 65)
        XCTAssertTrue(app.buttons["继续"].isHittable)
        capture("polish-largest-introduction-import", app)
        app.buttons["继续"].tap()
        XCTAssertTrue(app.buttons["继续"].isHittable)
        app.scrollViews.firstMatch.swipeUp()
        capture("polish-largest-introduction-quality", app)
        app.buttons["继续"].tap()
        XCTAssertTrue(app.buttons["完成介绍"].isHittable)
        app.scrollViews.firstMatch.swipeUp()
        capture("polish-largest-introduction-modes", app)
        app.buttons["关闭使用介绍"].tap()
    }
    @MainActor func testTabletPortraitAndLandscapeLayouts() throws {
        let device = XCUIDevice.shared
        let original = device.orientation
        defer { device.orientation = original }
        device.orientation = .landscapeLeft
        let app = launch()
        let windowSize = app.windows.firstMatch.frame.size
        guard min(windowSize.width, windowSize.height) > 600 else { throw XCTSkip("仅在已启动的 iPad 上检查横竖屏。") }
        XCTAssertGreaterThan(app.buttons["查看 远山来信"].frame.minX, 200)
        capture("ux-ipad-library-landscape", app)
        app.buttons["设置翻译"].tap()
        XCTAssertTrue(app.buttons["更改使用方式与 API 设置"].waitForExistence(timeout: 5))
        capture("ux-ipad-configuration-landscape", app)
        device.orientation = .portrait
        XCTAssertTrue(app.buttons["更改使用方式与 API 设置"].isHittable)
        capture("ux-ipad-configuration-portrait", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["进度"].tap()
        app.buttons["阅读已完成章节"].tap()
        XCTAssertTrue(app.buttons["返回本书进度"].waitForExistence(timeout: 5))
        capture("ux-ipad-reader-portrait", app)
        device.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["目录"].isHittable)
        capture("ux-ipad-reader-landscape", app)
        app.buttons["返回本书进度"].tap()
        XCTAssertTrue(app.buttons["关闭本书详情"].waitForExistence(timeout: 5))
    }
}
