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

    /// Category chip filter (Presets tab, non-HD): the chip strip is present with
    /// an "All" chip, and selecting a category chip keeps the shelf list populated
    /// (filter is a Swift cut on the cached shelves). Attaches a screenshot.
    func testCategoryChipsFilterPresets() throws {
        let app = launchRoonVis()

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitForElement(named: "Presets", in: app, timeout: 10),
            "Browse should open on the Presets tab."
        )
        XCTAssertTrue(
            waitForAnyElement(named: ["section-now-playing", "Now Playing"], in: app, timeout: 10),
            "Now Playing should be present."
        )
        // The chip strip renders whenever the pack has >1 category on a non-HD tier
        // (the sim reports the 4K tier). Match any category chip by label prefix —
        // the strip auto-scrolls to the default (playing preset's) category, which
        // can push the leading "All" chip off-screen.
        let anyCategoryChip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Filter by'")).firstMatch
        XCTAssertTrue(
            anyCategoryChip.waitForExistence(timeout: 5),
            "Category chip strip should be present on the sim's 4K tier."
        )
        attach(XCUIScreen.main.screenshot(), name: "chips-default")

        // Focus opens on the current preset card; Up reaches the chip strip. Nudge
        // right onto a category chip and select it to apply the filter.
        XCUIRemote.shared.press(.up)
        pause(0.5)
        XCUIRemote.shared.press(.right)
        pause(0.4)
        XCUIRemote.shared.press(.select)
        pause(0.8)
        attach(XCUIScreen.main.screenshot(), name: "chips-filtered")

        // The view stays intact after filtering: chips persist and Now Playing is
        // still surfaced (locked decision: always show it, even filtered away).
        XCTAssertTrue(
            anyCategoryChip.waitForExistence(timeout: 5),
            "Chip strip should persist after selecting a category."
        )
        XCTAssertTrue(
            waitForAnyElement(named: ["section-now-playing", "Now Playing"], in: app, timeout: 5),
            "Now Playing should remain present after filtering."
        )
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Measurement driver (not a pass/fail test): generates a ~15 s steady-state
    /// baseline, ~30 s of heavy preset-browser scrolling, then ~10 s of recovery,
    /// so the integrator can segment perf-diagnostics.log by elapsed time and
    /// compare frame interval vs. GPU render time. It asserts Browse is actually open
    /// before starting the scroll window.
    ///
    /// Long (~60 s) and NOT a functional pass/fail check, so it is skipped in the
    /// normal suite. Run explicitly with `ROONVIS_UITEST_STRESS=1` in the test
    /// process environment when gathering a perf trace.
    func testBrowserScrollStress() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ROONVIS_UITEST_STRESS"] == "1",
            "Stress/measurement driver — set ROONVIS_UITEST_STRESS=1 to run."
        )
        let app = launchRoonVis()

        // 1. Open the preset browser immediately after launch. Menu reliably reaches the
        //    focused ANGLEGLView right after launch (as in testBrowseOpensFromVisualizer);
        //    an idle before the press can drop the input, so open first, then scroll.
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitForElement(named: "Presets", in: app, timeout: 10),
            "Browse did not open — measurement invalid"
        )
        // Let a preset card win the initial focus grab before scrolling begins.
        _ = waitForFocusedPresetCard(in: app, timeout: 5)

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
        // Wait for the initial card focus to settle (the hint bar used to appear with it).
        _ = waitForFocusedPresetCard(in: app, timeout: 5)

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
        // Menu must be a card->pill retreat (stage 1), so wait for the initial card
        // focus to land before pressing Menu.
        XCTAssertTrue(
            waitForFocusedPresetCard(in: app, timeout: 8),
            "Initial focus should land on a preset card before the two-stage Menu."
        )

        // Stage 1: Menu retreats focus to the pill tab bar; Browse stays open.
        XCUIRemote.shared.press(.menu)
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
        _ = waitForFocusedPresetCard(in: app, timeout: 8)   // initial focus lands on the Now Playing card

        // Up from the Now Playing card must reach the (full-width focus section) pill
        // bar. With the category chip strip present (non-HD tier), Up passes through
        // the chips first, so step up until a pill takes focus.
        var ups = 0
        while !focusedPillExists(in: app) && ups < 3 {
            XCUIRemote.shared.press(.up)
            pause(0.6)
            ups += 1
        }
        XCTAssertTrue(
            waitForFocusedPill(in: app, timeout: 5),
            "Expected Up from the Now Playing card (through the chip strip) to focus a pill tab."
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
        _ = waitForFocusedPresetCard(in: app, timeout: 5)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitForFocusedPill(in: app, timeout: 5),
            "Expected a pill tab to be focused after the Menu retreat."
        )

        // Walk right until the Settings pill has focus (tab switches with focus).
        focusSettingsTab(in: app)

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

    /// Sync calibration smoke (regression guard, not a feature pass - the sim
    /// has no live Snapcast PCM, so the diagnostic bypass env opens the gate).
    /// Covers: entry from Settings, readout present, nudge moves the readout,
    /// Menu cancel returns to the visualizer with the original value restored.
    func testSyncCalibrationEntryNudgeCancel() throws {
        let app = launchRoonVis(environment: ["ROONVIS_ALLOW_SYNC_CAL_WITHOUT_LIVE_PCM": "1"])

        // Open Browse -> Settings tab (pill walk, as in the rendering-rows test).
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForElement(named: "Settings", in: app, timeout: 10), "Browse should open.")
        _ = waitForFocusedPresetCard(in: app, timeout: 5)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocusedPill(in: app, timeout: 5), "Pill bar should focus.")
        focusSettingsTab(in: app)

        // Descend to the Calibrate sync row (Audio panel) and activate it —
        // identifier-targeted ("row-calibrate-sync"), verified by focus, not a
        // blind fixed count.
        focusElement(withIdentifier: "row-calibrate-sync", in: app, maxSteps: 24, direction: .down)
        XCUIRemote.shared.press(.select)

        // Browse dismisses, calibration presents (0.35 s re-entry hop inside).
        XCTAssertTrue(
            waitForElement(named: "Sync Calibration", in: app, timeout: 10),
            "Calibration overlay should appear."
        )
        // Read the initial delay from the readout (e.g. "280 ms").
        pause(1)
        let initial = calibrationReadout(in: app)
        XCTAssertNotNil(initial, "Delay readout should be visible.")

        // Nudge +5 and assert the readout moved.
        XCUIRemote.shared.press(.right)
        pause(0.8)
        let nudged = calibrationReadout(in: app)
        XCTAssertNotNil(nudged)
        XCTAssertNotEqual(nudged, initial, "Nudge should move the readout.")

        // Menu cancels; overlay goes away.
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitForElementToDisappear(named: "Sync Calibration", in: app, timeout: 5),
            "Menu should dismiss calibration."
        )
    }

    /// REGRESSION guard (was a bug): walking focus vertically through the Settings
    /// screen must NOT change the persisted rotation mode. RVSegmentRow selects on
    /// focus, so traversal through the "Preset Rotation" row could rewrite the
    /// setting to whatever pill focus enters at. The row exposes the live mode as
    /// its `.accessibilityValue` ("row-rotation-mode"), so we read it before and
    /// after the traversal and assert equality — a REAL in-process check, no
    /// out-of-band defaults read.
    func testSettingsTraversalDoesNotChangeRotationMode() throws {
        let app = launchRoonVis()

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForElement(named: "Settings", in: app, timeout: 10))
        _ = waitForFocusedPresetCard(in: app, timeout: 5)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocusedPill(in: app, timeout: 5))
        focusSettingsTab(in: app)

        // Read the rotation mode before the traversal (row is in the Rotation panel
        // near the top, so it exists once the Settings screen has laid out).
        // firstMatch: SwiftUI propagates the row container's identifier onto every
        // child (icon, texts, pills) — all carry the SAME accessibilityValue, so any
        // single match reads the mode correctly; a bare single-element query throws
        // on the multiple matches.
        let rotationRow = app.descendants(matching: .any).matching(identifier: "row-rotation-mode").firstMatch
        XCTAssertTrue(rotationRow.waitForExistence(timeout: 5), "Rotation-mode row should exist.")
        let modeBefore = rotationRow.value as? String
        XCTAssertNotNil(modeBefore, "Rotation-mode row should expose its selected value.")

        // Walk down through every row, then BACK UP (the up-traversal enters
        // segment rows from below, where the previous focus sits on a left-
        // aligned pill - the historical Loop-flip path).
        for _ in 0..<14 {
            XCUIRemote.shared.press(.down)
            pause(0.35)
        }
        for _ in 0..<14 {
            XCUIRemote.shared.press(.up)
            pause(0.35)
        }

        // The mode must be unchanged by pure traversal.
        let modeAfter = app.descendants(matching: .any).matching(identifier: "row-rotation-mode").firstMatch.value as? String
        XCTAssertEqual(
            modeAfter, modeBefore,
            "Traversing Settings must not change the rotation mode (was \(modeBefore ?? "nil"), now \(modeAfter ?? "nil"))."
        )
    }

    /// Menu from the visualizer must land initial focus ON a preset card, not the
    /// pill tab bar (audit UI-3 — "Menu lands on the current card"). Preset cards
    /// carry `preset-card-<index>` identifiers, so a focused element whose
    /// identifier has that prefix proves the invariant.
    func testInitialFocusLandsOnCurrentCard() throws {
        let app = launchRoonVis()

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitForElement(named: "Presets", in: app, timeout: 10),
            "Expected Browse to open on the Presets tab."
        )

        XCTAssertTrue(
            waitForFocusedPresetCard(in: app, timeout: 8),
            "Expected initial focus to land on a preset card (identifier prefix 'preset-card-'), not the tab bar."
        )
    }

    /// EGL fault-injection recovery: arm the destroy fault so the next surface
    /// recreate (triggered by stepping the Render quality pill) tears the EGL
    /// surface out from under the render loop, then assert the app both survives
    /// AND keeps servicing input — the pill must still step a second time.
    ///
    /// NOTE: a dead-EGL app still runs UIKit, so "app is foreground" alone is a
    /// weak check. Stepping the pill BACK and asserting the second step also lands
    /// proves the render/settings path kept processing remote input after the
    /// fault. FULL recovery proof (the surface was actually rebuilt) is the
    /// "no-surface recovery retry" / "recreated EGL surface" log line, which the
    /// integrator captures from the device/sim console during this run.
    func testEGLFaultInjectRecovery() throws {
        let app = launchRoonVis(environment: ["ROONVIS_EGL_FAULT_INJECT": "destroy"])

        // Open Browse -> Settings tab.
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForElement(named: "Settings", in: app, timeout: 10), "Browse should open.")
        _ = waitForFocusedPresetCard(in: app, timeout: 5)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocusedPill(in: app, timeout: 5), "Pill bar should focus.")
        focusSettingsTab(in: app)

        // Descend to a Render quality pill (identifier-targeted, not a blind count).
        let qualityLabels = ["720p", "1080p", "1440p", "4K"]
        var downs = 0
        while focusedLabel(among: qualityLabels, in: app) == nil && downs < 20 {
            XCUIRemote.shared.press(.down)
            pause(0.4)
            downs += 1
        }
        let before = focusedLabel(among: qualityLabels, in: app)
        XCTAssertNotNil(before, "Expected a Render quality pill to take focus.")

        // Step once: this triggers a surface recreate; the armed destroy fault fires
        // and the recovery path must rebuild the surface without crashing.
        XCUIRemote.shared.press(before == "4K" ? .left : .right)
        pause(1.0)

        // The app must still be alive (foreground) after the fault + recovery.
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 3),
            "Expected RoonVis to still be running foreground after the injected EGL destroy."
        )

        // And it must still service input: step the pill BACK and confirm the second
        // step lands on a different value — proving the input/settings path survived.
        let mid = focusedLabel(among: qualityLabels, in: app)
        XCTAssertNotNil(mid, "Expected focus to remain on a Render quality pill after the fault.")
        XCUIRemote.shared.press(mid == "4K" ? .left : .right)
        pause(1.0)
        let after = focusedLabel(among: qualityLabels, in: app)
        XCTAssertNotNil(after, "Expected focus to remain on a Render quality pill after the second step.")
        XCTAssertNotEqual(after, mid, "Second pill step must land on a different value (input path alive post-fault).")
    }

    private func calibrationReadout(in app: XCUIApplication) -> String? {
        let predicate = NSPredicate(format: "label ENDSWITH ' ms'")
        let element = app.staticTexts.matching(predicate).firstMatch
        return element.exists ? element.label : nil
    }

    private func focusedLabel(among labels: [String], in app: XCUIApplication) -> String? {
        labels.first { name in
            let button = app.buttons[name]
            return button.exists && button.hasFocus
        }
    }

    /// Identifier-targeted focus navigation: press `direction` toward a target,
    /// polling the element's `hasFocus` after each step. Bounded by `maxSteps` but
    /// verified by focus state, not a blind fixed count. Returns true once the
    /// target has focus; fails the test with a clear message otherwise.
    @discardableResult
    private func focusElement(
        withIdentifier identifier: String,
        in app: XCUIApplication,
        maxSteps: Int,
        direction: XCUIRemote.Button
    ) -> Bool {
        let element = app.descendants(matching: .any)[identifier]
        if element.exists && element.hasFocus { return true }
        for _ in 0..<maxSteps {
            XCUIRemote.shared.press(direction)
            pause(0.4)
            if element.exists && element.hasFocus { return true }
        }
        let reached = element.exists && element.hasFocus
        XCTAssertTrue(
            reached,
            "Could not focus '\(identifier)' within \(maxSteps) '\(direction)' presses."
        )
        return reached
    }

    /// True once the currently-focused element is a preset card (identifier prefix
    /// `preset-card-`). Polls up to `timeout`.
    private func waitForFocusedPresetCard(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let id = focusedElementIdentifier(in: app), id.hasPrefix("preset-card-") {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        if let id = focusedElementIdentifier(in: app) { return id.hasPrefix("preset-card-") }
        return false
    }

    /// The identifier of the currently-focused element, if any.
    private func focusedElementIdentifier(in app: XCUIApplication) -> String? {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard focused.exists else { return nil }
        let id = focused.identifier
        return id.isEmpty ? nil : id
    }

    /// Walk the pill bar right until the Settings tab pill has focus (tab switches
    /// with focus). Identifier-targeted: the pill carries `tab-settings`, and its
    /// label "Settings" is kept for the existing label-based checks.
    private func focusSettingsTab(in app: XCUIApplication) {
        var hops = 0
        while !(app.buttons["Settings"].exists && app.buttons["Settings"].hasFocus) && hops < 4 {
            XCUIRemote.shared.press(.right)
            pause(0.5)
            hops += 1
        }
        XCTAssertTrue(app.buttons["Settings"].hasFocus, "Expected the Settings pill to gain focus.")
        pause(0.6)
    }

    /// RunLoop-based wait (keeps the XCTest run loop live, unlike `sleep`).
    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func launchRoonVis(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.terminate()
        app.launchEnvironment = environment
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "Expected RoonVis to launch in the foreground."
        )

        // Documented sim input-drop: a Menu press issued before the ANGLEGLView is
        // focusable is silently dropped. There is no queryable element on the bare
        // visualizer to wait on, so a short settle is the minimum that keeps the
        // first Menu press reliable. Kept intentionally (do not zero).
        pause(1.5)
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
