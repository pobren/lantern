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
        let row = text("Your order is on its way")
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
        launch("inbox")
        if tap(button("New message")) {
            pause(1.2)
            let to = app.textFields.element(boundBy: 0)
            if to.waitForExistence(timeout: 4) { to.tap(); type("maya@studio-north.example", into: to) }
            pause(0.4)
            let subject = app.textFields.element(boundBy: 1)
            if subject.exists { subject.tap(); type("Lunch on Friday?", into: subject) }
            pause(0.4)
            let body = app.textViews.firstMatch
            if body.exists {
                body.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.02)).tap(); pause(0.4)
                type("Hi Maya, are you free for lunch on Friday? My treat.", into: body)
            }
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
        for who in ["Tom Okafor", "Ana Rodrigues", "Leo Park", "Maya Chen"] {
            let row = app.outlines.cells.containing(.staticText, identifier: who).firstMatch
            let g = row.exists ? row : app.tables.cells.containing(.staticText, identifier: who).firstMatch
            tap(g.exists ? g : app.staticTexts[who].firstMatch); pause(1.8)
        }
        // A new message, typed out.
        app.typeKey("n", modifierFlags: .command); pause(1.5)
        let to = app.textFields.element(boundBy: 0)
        if to.waitForExistence(timeout: 4) { to.click(); type("maya@studio-north.example", into: to) }
        let subject = app.textFields.element(boundBy: 1)
        if subject.exists { subject.click(); type("Lunch on Friday?", into: subject) }
        let body = app.textViews.firstMatch
        if body.exists {
            body.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.02)).click(); pause(0.3)
            type("Hi Maya, are you free for lunch on Friday? My treat.", into: body)
        }
        pause(2.5)
        app.typeKey(.escape, modifierFlags: []); pause(1)
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
