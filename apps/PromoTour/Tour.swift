// Films the promo video: each test is one scene, played out on sample mail while the workflow records the screen
// (promo-footage.yml). Nothing here checks anything; the pauses are there so the footage reads well.

import XCTest

final class Tour: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private func launch(_ screen: String, _ extra: [String] = []) {
        app.launchArguments = ["-JCDemo", "-JCTour", "-JCScreen", screen] + extra
        app.launch()
        pause(3)
    }

    private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    /// Types like a person, a few letters at a time.
    private func type(_ text: String, into element: XCUIElement) {
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            element.typeText(String(word) + " ")
            pause(0.12)
        }
    }

    @discardableResult private func tap(_ e: XCUIElement, wait: Double = 6) -> Bool {
        guard e.waitForExistence(timeout: wait) else { print("PROMO missing \(e)"); return false }
        #if os(iOS)
        e.tap()
        #else
        e.click()
        #endif
        return true
    }

    private func text(_ s: String) -> XCUIElement { app.staticTexts[s].firstMatch }
    private func button(_ s: String) -> XCUIElement { app.buttons[s].firstMatch }

    #if os(iOS)
    // MARK: iPhone

    func test1Inbox() {
        launch("inbox")
        let list = app.collectionViews.firstMatch
        list.swipeUp(velocity: 400); pause(1.2)
        list.swipeDown(velocity: 400); pause(1.2)
        // Swipe a newsletter away to the archive.
        let row = text("Your loyalty card is full")
        if row.waitForExistence(timeout: 4) {
            row.swipeLeft(velocity: 600); pause(1.2)
            tap(button("Archive")); pause(1.5)
        }
        tap(text("Sketches for the spring launch")); pause(3)
        app.webViews.firstMatch.swipeUp(velocity: 300); pause(1.5)
        app.webViews.firstMatch.swipeDown(velocity: 500); pause(1.5)
    }

    func test2Labels() {
        launch("email")
        pause(1)
        if tap(button("More")) {
            pause(1.2)
            if tap(button("Labels")) { pause(2); tap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Clients'")).firstMatch); pause(2) }
        }
    }

    func test3Reply() {
        launch("email")
        if tap(button("Reply")) {
            pause(0.8)
            if !tap(app.buttons.matching(NSPredicate(format: "label == 'Reply'")).element(boundBy: 1), wait: 2) {
                tap(app.buttons["Reply"].firstMatch, wait: 2)
            }
        }
        pause(1.5)
        let body = app.textViews.firstMatch
        if body.waitForExistence(timeout: 5) {
            // Tap the very top of the email, above the signature and the quote.
            body.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.0)).withOffset(CGVector(dx: 0, dy: 8)).tap(); pause(0.6)
            type("Love the second direction, Maya. Let's go with it and I'll send the final copy on Thursday.", into: body)
        }
        pause(2.5)
    }

    func test4Search() {
        launch("inbox")
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 3) { app.collectionViews.firstMatch.swipeDown(velocity: 300) }
        if tap(field) {
            pause(0.6)
            type("Lisbon", into: field)
            pause(3)
            app.keyboards.buttons["search"].tap()
            pause(2.5)
        }
    }

    func test5Masked() {
        launch("settings")
        let form = app.collectionViews.firstMatch
        for _ in 0..<6 where !button("Masked addresses").isHittable {
            form.swipeUp(velocity: 500); pause(0.4)
        }
        pause(1)
        if tap(button("Masked addresses")) {
            pause(2.5)
            if tap(button("New masked address")) {
                pause(1.2)
                let note = app.textFields.firstMatch
                if tap(note) { type("Garden centre", into: note) }
                pause(0.8)
                tap(button("Make and copy")); pause(3)
            }
        }
    }

    func test6Alert() {
        // A real iOS alert: the app is closed to the home screen, then mail arrives.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments = ["-JCDemo", "-JCTour", "-JCAlert", "-JCScreen", "inbox"]
        app.launch()
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        pause(2)
        XCUIDevice.shared.press(.home)
        let banner = springboard.otherElements["Notification"].firstMatch
        if banner.waitForExistence(timeout: 12) || springboard.otherElements.matching(NSPredicate(format: "label CONTAINS 'Maya'")).firstMatch.waitForExistence(timeout: 4) {
            pause(2.5)
            let target = banner.exists ? banner : springboard.otherElements.matching(NSPredicate(format: "label CONTAINS 'Maya'")).firstMatch
            target.press(forDuration: 1.2)
            pause(3.5)
            if springboard.buttons["Archive"].waitForExistence(timeout: 3) { springboard.buttons["Archive"].tap() }
            pause(2)
        } else {
            pause(8)
        }
    }

    func test7Dark() {
        // The workflow switches the simulator to dark mode before this one.
        launch("inbox")
        pause(1)
        tap(text("Re: Lisbon in April")); pause(3)
        app.webViews.firstMatch.swipeUp(velocity: 300); pause(2)
    }
    #else
    // MARK: Mac

    func test1MacTour() {
        launch("email")
        pause(1)
        // Down the list with the arrow keys, then back up to Maya's email.
        tap(app.staticTexts["Maya Chen"].firstMatch); pause(0.5)
        for key in [XCUIKeyboardKey.downArrow, .downArrow, .downArrow, .downArrow, .upArrow, .upArrow, .upArrow, .upArrow] {
            app.typeKey(key, modifierFlags: []); pause(1.3)
        }
        pause(1)
        // Reply, typed at the top above the quote.
        app.typeKey("r", modifierFlags: .command); pause(1.5)
        let body = app.textViews.firstMatch
        if body.waitForExistence(timeout: 5) {
            body.click(); pause(0.3)
            app.typeKey(.upArrow, modifierFlags: .command); pause(0.4)
            type("Hi Maya, love the second direction. Let's go with it.", into: body)
            app.typeKey(.return, modifierFlags: []); app.typeKey(.return, modifierFlags: [])
            pause(2)
        }
        app.typeKey(.escape, modifierFlags: []); pause(1)
        if button("Delete draft").exists { button("Delete draft").click() }
        else if button("Don't save").exists { button("Don't save").click() }
        pause(1)
    }

    func test2MacSearch() {
        launch("email")
        let field = app.textFields["Search"].firstMatch
        if field.waitForExistence(timeout: 5) {
            field.click(); pause(0.5)
            type("Lisbon", into: field)
            pause(2)
            app.typeKey(.return, modifierFlags: []); pause(3)
        }
    }

    func test3MacFolders() {
        launch("email")
        for folder in ["Clients", "Travel", "Inbox"] {
            let f = app.outlines.cells.containing(.staticText, identifier: folder).firstMatch
            let g = f.exists ? f : app.staticTexts[folder].firstMatch
            if g.waitForExistence(timeout: 3) { g.click(); pause(2.2) }
        }
    }

    func test4MacMasked() {
        launch("email")
        app.typeKey(",", modifierFlags: .command); pause(2)
        let settings = app.windows.matching(NSPredicate(format: "title CONTAINS 'Settings' OR title CONTAINS 'General'")).firstMatch
        let scroller = settings.exists ? settings.scrollViews.firstMatch : app.scrollViews.firstMatch
        for _ in 0..<5 where !button("Masked addresses").isHittable { scroller.scroll(byDeltaX: 0, deltaY: -200); pause(0.4) }
        if tap(button("Masked addresses")) {
            pause(2.5)
            if tap(button("New masked address")) {
                pause(1)
                let note = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS 'Netflix'")).firstMatch
                if tap(note) { type("Garden centre", into: note) }
                pause(0.6)
                tap(button("Make and copy")); pause(3)
            }
        }
    }

    func test5MacDark() {
        launch("email", ["-JCDark"])
        tap(app.staticTexts["Maya Chen"].firstMatch); pause(0.5)
        for key in [XCUIKeyboardKey.downArrow, .downArrow, .upArrow, .upArrow] {
            app.typeKey(key, modifierFlags: []); pause(1.6)
        }
    }
    #endif
}
