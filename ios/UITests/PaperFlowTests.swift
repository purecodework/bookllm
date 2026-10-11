import XCTest

final class PaperFlowTests: XCTestCase {
    @MainActor private func launch(parallel: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--paper-ui-testing", "--paper-ui-reset"] + (parallel ? ["--paper-ui-parallel"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["导入文稿"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    @MainActor func testQualityRolesSearchAndImportNavigation() {
        let app = launch()
        capture("01-library", app: app)
        app.buttons["设置翻译"].tap()
        XCTAssertTrue(app.staticTexts["主编"].waitForExistence(timeout: 5))
        capture("02-quality-premium", app: app)
        app.buttons["速读"].tap()
        XCTAssertFalse(app.staticTexts["主编"].exists)
        XCTAssertFalse(app.staticTexts["校对"].exists)
        capture("02-quality-fast", app: app)
        app.buttons["精译"].tap()
        XCTAssertTrue(app.staticTexts["校对"].exists)
        XCTAssertFalse(app.staticTexts["语言专家"].exists)
        app.buttons["深校"].tap()
        XCTAssertTrue(app.staticTexts["语言专家"].exists)
        XCTAssertFalse(app.staticTexts["主编"].exists)
        for _ in 0..<2 { app.buttons["精修"].tap(); app.buttons["速读"].tap() }
        app.buttons["精修"].tap()
        XCTAssertTrue(app.staticTexts["主编"].exists)
        XCTAssertFalse(app.staticTexts["整合校对与语言专家意见，依据原文解决冲突，协调节奏与人物声音。"].exists)
        for _ in 0..<5 where !app.buttons["role-pipeline-details"].isHittable { app.scrollViews.firstMatch.swipeUp() }
        app.buttons["role-pipeline-details"].tap()
        XCTAssertTrue(app.staticTexts["整合校对与语言专家意见，依据原文解决冲突，协调节奏与人物声音。"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["导入文稿"].waitForExistence(timeout: 5))
        app.buttons["搜索文稿"].tap()
        app.textFields["搜索书名"].tap()
        app.textFields["搜索书名"].typeText("no-match")
        XCTAssertTrue(app.staticTexts["没有找到文稿"].exists)
        app.buttons["清除搜索"].firstMatch.tap()
        XCTAssertTrue(app.buttons["远山来信"].exists)
        app.buttons["导入文稿"].tap()
        XCTAssertTrue(app.buttons["选择文件"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["扫描纸张"].exists)
        capture("08-import", app: app)
    }
    @MainActor func testNameEditingAndKeyboardValidation() {
        let app = launch()
        app.buttons["午后的花园 的菜单"].tap()
        app.buttons["译名"].tap()
        XCTAssertTrue(app.buttons["修改 Elizabeth 的译名"].waitForExistence(timeout: 5))
        capture("06-names", app: app)
        app.buttons["修改 Elizabeth 的译名"].tap()
        let field = app.textFields["译名"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let old = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["请输入译名。"].exists)
        capture("07-edit-name-keyboard", app: app)
        field.typeText("莉莎")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["莉莎"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已修改"].exists)
    }
    @MainActor func testCompletedReaderAndOriginalMode() {
        let app = launch()
        app.buttons["library-read-paper-complete"].tap()
        XCTAssertTrue(app.buttons["原文"].waitForExistence(timeout: 5))
        capture("04-reader-fullpage", app: app)
        app.buttons["原文"].tap()
        XCTAssertTrue(app.staticTexts["Elizabeth opened a letter."].waitForExistence(timeout: 5))
        app.buttons["译文"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "午后的光越过窗沿")).firstMatch.exists)
        app.buttons["阅读字号"].tap()
        app.buttons["更大字号"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "午后的光越过窗沿")).firstMatch.isHittable)
    }
    @MainActor func testLargeTypeKeepsPrimaryActionReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--paper-ui-testing", "--paper-ui-reset", "--paper-ui-large-type"]
        app.launch()
        XCTAssertTrue(app.buttons["设置翻译"].waitForExistence(timeout: 10))
        app.buttons["设置翻译"].tap()
        XCTAssertTrue(app.buttons["点数服务暂不可用"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["更改使用方式与 API 设置"].isHittable)
        capture("large-type", app: app)
        for _ in 0..<3 where !app.buttons["精修"].isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(app.buttons["精修"].isHittable)
        app.buttons["精译"].tap()
        XCTAssertFalse(app.staticTexts["主编"].exists)
        XCTAssertTrue(app.buttons["更改使用方式与 API 设置"].isHittable)
    }
    @MainActor func testProgressReaderReturnAndPauseConfirmation() {
        let app = launch(parallel: true)
        XCTAssertTrue(app.staticTexts["校对与语言专家并行审校"].waitForExistence(timeout: 5))
        app.buttons["进度"].tap()
        XCTAssertTrue(app.buttons["校对，处理中"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["语言专家，处理中"].exists)
        capture("03-progress", app: app)
        app.buttons["阅读已完成章节"].tap()
        XCTAssertTrue(app.buttons["对照"].waitForExistence(timeout: 5))
        capture("04-reader", app: app)
        app.buttons["对照"].tap()
        XCTAssertTrue(app.buttons["对照"].isSelected)
        capture("05-bilingual", app: app)
        app.buttons["阅读字号"].tap()
        app.buttons["更大字号"].tap()
        app.buttons["返回本书进度"].tap()
        XCTAssertTrue(app.buttons["暂停翻译"].waitForExistence(timeout: 5))
        app.buttons["暂停翻译"].tap()
        XCTAssertTrue(app.staticTexts["已暂停"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["点数服务暂不可用"].exists)
        app.buttons["关闭本书详情"].tap()
        XCTAssertTrue(app.buttons["导入文稿"].waitForExistence(timeout: 5))
    }
}
