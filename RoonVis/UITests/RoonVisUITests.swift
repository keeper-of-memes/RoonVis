import XCTest

final class RoonVisUITests: XCTestCase {
    private let appBundleIdentifier = "local.roon-vis.gate-step-a"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBrowseOpensFromVisualizer() throws {
        let app = launchRoonVis()

        XCUIRemote.shared.press(.menu)

        XCTAssertTrue(
            waitForElement(named: "Presets", in: app, timeout: 10),
            "Expected Browse to open with the Presets tab visible."
        )
        XCTAssertTrue(
            waitForElement(named: "Favorites", in: app, timeout: 2),
            "Expected Browse tab bar to include Favorites."
        )
        XCTAssertTrue(
            waitForElement(named: "Settings", in: app, timeout: 2),
            "Expected Browse tab bar to include Settings."
        )
    }

    func testPresetsTabHasNowPlayingSection() throws {
        let app = launchRoonVis()

        XCUIRemote.shared.press(.menu)

        XCTAssertTrue(
            waitForElement(named: "Presets", in: app, timeout: 10),
            "Expected Browse to open on or expose the Presets tab."
        )
        XCTAssertTrue(
            waitForAnyElement(named: ["section-now-playing", "Now Playing"], in: app, timeout: 10),
            "Expected the Presets tab to include a Now Playing section."
        )
    }

    /// Measurement driver (not a pass/fail test): generates a ~15 s steady-state
    /// baseline, ~30 s of heavy preset-browser scrolling, then ~10 s of recovery,
    /// so the integrator can segment perf-diagnostics.log by elapsed time and
    /// compare frame interval vs. GPU render time. It asserts Browse is actually open
    /// before starting the scroll window.
    func testBrowserScrollStress() throws {
        let app = launchRoonVis()

        // 1. Open the preset browser immediately after launch. Menu reliably reaches the
        //    focused ANGLEGLView right after launch (as in testBrowseOpensFromVisualizer);
        //    an idle before the press can drop the input, so open first, then scroll.
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitForElement(named: "Presets", in: app, timeout: 10),
            "Browse did not open — measurement invalid"
        )
        pause(3)

        // 3. Scroll hard for ~30 s: continuous focus movement across thumbnails.
        //    Each loop iteration is ~10 presses * ~0.3 s ≈ 3 s, so ~10 iterations.
        let scrollDeadline = Date().addingTimeInterval(30)
        while Date() < scrollDeadline {
            for _ in 0..<4 {
                XCUIRemote.shared.press(.right)
                pause(0.3)
            }
            XCUIRemote.shared.press(.down)
            pause(0.3)
            for _ in 0..<4 {
                XCUIRemote.shared.press(.left)
                pause(0.3)
            }
            XCUIRemote.shared.press(.up)
            pause(0.3)
        }

        // 4. Return to the visualizer and record a recovery window (~10 s).
        //    Menu is two-stage inside Browse: first press moves focus to the pill
        //    tab bar, second press dismisses.
        XCUIRemote.shared.press(.menu)
        pause(0.5)
        XCUIRemote.shared.press(.menu)
        pause(10)

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 5),
            "Expected RoonVis to still be running in the foreground after the stress run."
        )
    }

    func testHintBarRemoved() throws {
        let app = launchRoonVis()

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitForElement(named: "Presets", in: app, timeout: 10),
            "Expected Browse to open."
        )
        pause(2)   // let the initial card focus settle (the hint bar used to appear with it)

        XCTAssertFalse(app.staticTexts["Play to favorite"].exists, "Hint capsule should be removed.")
        XCTAssertFalse(app.staticTexts["Select to switch"].exists, "Hint capsule should be removed.")
        XCTAssertFalse(app.staticTexts["Hold Select for options"].exists, "Hint capsule should be removed.")
    }

    func testMenuIsTwoStageInsideBrowse() throws {
        let app = launchRoonVis()

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitForElement(named: "Presets", in: app, timeout: 10),
            "Expected Browse to open."
        )
        pause(2)   // initial focus lands on the Now Playing card

        // Stage 1: Menu retreats focus to the pill tab bar; Browse stays open.
        XCUIRemote.shared.press(.menu)
        pause(1)
        XCTAssertTrue(
            waitForElement(named: "Presets", in: app, timeout: 3),
            "Browse must still be open after the first Menu press."
        )
        XCTAssertTrue(
            waitForFocusedPill(in: app, timeout: 5),
            "Expected a pill tab to be focused after the first Menu press."
        )

        // Stage 2: Menu with a pill focused dismisses Browse.
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitForElementToDisappear(named: "Favorites", in: app, timeout: 5),
            "Expected Browse to close on the second Menu press."
        )
    }

    func testUpFromNowPlayingReachesPillsAndTabSwitchKeepsPills() throws {
        let app = launchRoonVis()

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitForElement(named: "Presets", in: app, timeout: 10),
            "Expected Browse to open."
        )
        pause(2)   // initial focus lands on the Now Playing card

        // Up from the Now Playing card must reach the (full-width focus section) pill bar.
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(
            waitForFocusedPill(in: app, timeout: 5),
            "Expected Up from the Now Playing card to focus a pill tab."
        )

        // Switching tabs left/right must keep focus on the pills (no card focus yank).
        XCUIRemote.shared.press(.left)
        pause(1)
        XCTAssertTrue(
            waitForFocusedPill(in: app, timeout: 3),
            "Expected focus to stay on the pill bar after Left (tab switch)."
        )
        XCUIRemote.shared.press(.right)
        pause(1)
        XCTAssertTrue(
            waitForFocusedPill(in: app, timeout: 3),
            "Expected focus to stay on the pill bar after Right (tab switch)."
        )
    }

    func testLongPressSelectOpensPresetOptions() throws {
        let app = launchRoonVis()

        XCUIRemote.shared.press(.select, forDuration: 1.0)
        XCTAssertTrue(
            waitForElement(named: "Hide Preset", in: app, timeout: 10),
            "Expected the preset options overlay after a long Select press."
        )

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitForElementToDisappear(named: "Hide Preset", in: app, timeout: 5),
            "Expected Menu to dismiss the preset options overlay."
        )
    }

    /// Settings rows: the Frame rate and Render quality segment rows exist and
    /// respond to remote stepping. In RVSegmentRow focus IS selection (moving
    /// focus onto a pill selects it), so asserting the focused pill changed
    /// also proves the underlying setting changed.
    func testRenderingSettingsRowsStep() throws {
        let app = launchRoonVis()

        // Open Browse, then retreat focus to the pill tab bar.
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitForElement(named: "Settings", in: app, timeout: 10),
            "Expected Browse to open with the Settings tab pill."
        )
        pause(2)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitForFocusedPill(in: app, timeout: 5),
            "Expected a pill tab to be focused after the Menu retreat."
        )

        // Walk right until the Settings pill has focus (tab switches with focus).
        var hops = 0
        while !(app.buttons["Settings"].exists && app.buttons["Settings"].hasFocus) && hops < 4 {
            XCUIRemote.shared.press(.right)
            pause(0.5)
            hops += 1
        }
        XCTAssertTrue(app.buttons["Settings"].hasFocus, "Expected the Settings pill to gain focus.")
        pause(1)

        // Descend through the settings rows until a frame-rate pill has focus.
        let frameRateLabels = ["25", "30", "50", "60"]
        var downs = 0
        while focusedLabel(among: frameRateLabels, in: app) == nil && downs < 20 {
            XCUIRemote.shared.press(.down)
            pause(0.4)
            downs += 1
        }
        let initialRate = focusedLabel(among: frameRateLabels, in: app)
        XCTAssertNotNil(initialRate, "Expected a Frame rate pill to take focus while descending Settings.")

        // Step the frame-rate row: focus (= selection) must land on a different value.
        XCUIRemote.shared.press(initialRate == "60" ? .left : .right)
        pause(0.6)
        let steppedRate = focusedLabel(among: frameRateLabels, in: app)
        XCTAssertNotNil(steppedRate, "Expected focus to remain on a Frame rate pill after stepping.")
        XCTAssertNotEqual(steppedRate, initialRate, "Expected stepping to select a different frame rate.")

        // Next row down is Render quality; step it the same way.
        let qualityLabels = ["720p", "1080p", "1440p", "4K"]
        downs = 0
        while focusedLabel(among: qualityLabels, in: app) == nil && downs < 4 {
            XCUIRemote.shared.press(.down)
            pause(0.4)
            downs += 1
        }
        let initialQuality = focusedLabel(among: qualityLabels, in: app)
        XCTAssertNotNil(initialQuality, "Expected a Render quality pill to take focus below Frame rate.")

        XCUIRemote.shared.press(initialQuality == "4K" ? .left : .right)
        pause(1.0)   // surface recreation happens on this change; give it a beat
        let steppedQuality = focusedLabel(among: qualityLabels, in: app)
        XCTAssertNotNil(steppedQuality, "Expected focus to remain on a Render quality pill after stepping.")
        XCTAssertNotEqual(steppedQuality, initialQuality, "Expected stepping to select a different render quality.")
    }

    private func focusedLabel(among labels: [String], in app: XCUIApplication) -> String? {
        labels.first { name in
            let button = app.buttons[name]
            return button.exists && button.hasFocus
        }
    }

    /// RunLoop-based wait (keeps the XCTest run loop live, unlike `sleep`).
    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func launchRoonVis() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.terminate()
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Expected RoonVis to launch in the foreground."
        )

        RunLoop.current.run(until: Date().addingTimeInterval(3))
        return app
    }

    private func waitForElement(named name: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if elementExists(named: name, in: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return elementExists(named: name, in: app)
    }

    private func waitForAnyElement(named names: [String], in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if names.contains(where: { elementExists(named: $0, in: app) }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return names.contains(where: { elementExists(named: $0, in: app) })
    }

    private func waitForElementToDisappear(named name: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if !elementExists(named: name, in: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return !elementExists(named: name, in: app)
    }

    private func focusedPillExists(in app: XCUIApplication) -> Bool {
        ["Favorites", "Presets", "Settings"].contains { name in
            let button = app.buttons[name]
            return button.exists && button.hasFocus
        }
    }

    private func waitForFocusedPill(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if focusedPillExists(in: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return focusedPillExists(in: app)
    }

    private func elementExists(named name: String, in app: XCUIApplication) -> Bool {
        app.staticTexts[name].exists
            || app.buttons[name].exists
            || app.otherElements[name].exists
            || app.descendants(matching: .any)[name].exists
    }
}
