import XCTest

/// 真拉一下列表，CI 同时录屏（ios.yml 的 pulltest）。效果看录屏，这里只管手势和结果。
final class PullRefreshUITests: XCTestCase {
    private func launch(_ scene: String) -> XCUIApplication {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchEnvironment["SH_DEMO"] = scene
        app.launch()
        sleep(3)
        return app
    }

    /// 先拉一半松手（不该刷新），再拉到底停一下（该刷新）
    private func pull(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 70)), withVelocity: .init(60), thenHoldForDuration: 1)
        sleep(2)
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 300)), withVelocity: .init(120), thenHoldForDuration: 1)
        sleep(3)
    }

    func test1NewOrder() { pull(launch("refresh-new")) }

    func test2Fail() {
        let app = launch("refresh-fail")
        pull(app)
        XCTAssertTrue(app.staticTexts["没连上，下拉也能再试"].waitForExistence(timeout: 3), "刷新失败要有提示")
    }

    func test3Rent() { pull(launch("rent")) }

    func test4Me() { pull(launch("me")) }

    func test5MeFail() {
        let app = launch("me-refresh-fail")
        pull(app)
    }

    /// 滑到底，先拉一点松手（不该刷新），再拉够（该刷新并回到顶部）
    private func pullAtEnd(_ app: XCUIApplication) {
        for _ in 0..<6 { app.swipeUp(velocity: .fast); usleep(400_000) }
        sleep(2)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -50)), withVelocity: .init(60), thenHoldForDuration: 1)
        sleep(2)
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -300)), withVelocity: .init(120), thenHoldForDuration: 1)
        sleep(4)
    }

    func test6EndNewOrder() { pullAtEnd(launch("refresh-new")) }

    func test7EndRent() { pullAtEnd(launch("rent")) }
}
