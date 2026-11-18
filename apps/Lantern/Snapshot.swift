// Mac only, and only when launched for the App Store screenshots (-JCDemo): the app draws its own window into a
// picture, so the screenshot workflow needs no Screen Recording permission on GitHub's Macs. Email bodies are web
// views, which don't draw into a cached picture, so each is snapshotted on its own and laid on top.

#if os(macOS)
import AppKit
import WebKit

enum Snapshot {
    @MainActor static func save(_ name: String) async {
        let windows = NSApp.windows
        NSLog("JCDEBUG windows: " + windows.map { "\(type(of: $0)) visible=\($0.isVisible) main=\($0.canBecomeMain) \($0.frame)" }.joined(separator: " | "))
        guard let w = windows.first(where: { $0.canBecomeMain && $0.contentView != nil && $0.attachedSheet != nil })
                ?? windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) else {
            NSLog("JCDEBUG no window to snapshot"); fflush(stdout); return
        }
        guard let base = await picture(of: w) else { NSLog("JCDEBUG snapshot failed"); fflush(stdout); return }
        let image = NSImage(size: w.frame.size)
        image.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: w.frame.size))
        if let sheet = w.attachedSheet, let pic = await picture(of: sheet) {
            pic.draw(in: NSRect(x: sheet.frame.minX - w.frame.minX, y: sheet.frame.minY - w.frame.minY,
                                width: sheet.frame.width, height: sheet.frame.height))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jc-\(name).png")
        do {
            try png.write(to: url)
            NSLog("JCSHOT \(url.path)")
        } catch { NSLog("JCDEBUG write failed \(error)") }
        fflush(stdout)
    }

    /// The whole window, title bar included, with any email web views drawn in.
    @MainActor private static func picture(of window: NSWindow) async -> NSImage? {
        guard let content = window.contentView else { return nil }
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        var webs: [(NSImage, NSRect)] = []
        for web in webViews(in: view) where !web.isHiddenOrHasHiddenAncestor && web.bounds.width > 0 {
            if let shot = try? await web.takeSnapshot(configuration: nil) {
                var r = web.convert(web.bounds, to: view)
                if view.isFlipped { r.origin.y = view.bounds.height - r.maxY }
                webs.append((shot, r))
            }
        }
        guard !webs.isEmpty else { return image }
        let out = NSImage(size: view.bounds.size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        for (shot, r) in webs { shot.draw(in: r) }
        out.unlockFocus()
        return out
    }

    @MainActor private static func webViews(in view: NSView) -> [WKWebView] {
        var found: [WKWebView] = []
        for sub in view.subviews {
            if let web = sub as? WKWebView { found.append(web) } else { found += webViews(in: sub) }
        }
        return found
    }
}
#endif
