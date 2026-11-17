// Shows an email the way its sender laid it out, safely: no scripts, nothing it can submit, links open in your
// browser, and pictures from the web load only when you allow them (Settings, or the button on the email).

import SwiftUI
import WebKit

struct EmailWebView: NSViewRepresentable {
    let html: String
    let remoteImages: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()          // no cookies kept between emails
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let page = Self.wrap(html, remoteImages: remoteImages)
        guard context.coordinator.loaded != page else { return }
        context.coordinator.loaded = page
        view.loadHTMLString(page, baseURL: nil)
    }

    /// Wraps the email in a page with a strict content policy: inline styles and data: pictures always,
    /// web pictures, styles and fonts only when allowed, and never scripts, frames, forms or plugins.
    static func wrap(_ html: String, remoteImages: Bool) -> String {
        let web = remoteImages ? " https: http:" : ""
        let policy = "default-src 'none'; img-src data:\(web); style-src 'unsafe-inline'\(web); font-src data:\(web); media-src data:\(web); form-action 'none'; frame-src 'none'; script-src 'none'"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html { -webkit-text-size-adjust: 100%; }
          body { margin: 0; padding: 4px 0 40px; font: 14.5px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; color: #16191D; word-wrap: break-word; overflow-wrap: anywhere; }
          img { max-width: 100%; height: auto; }
          table { max-width: 100% !important; }
          .lantern-text { white-space: pre-wrap; }
          a { color: #2F5BD3; }
          blockquote { margin: 0 0 0 10px; padding-left: 12px; border-left: 3px solid #E3E6EB; color: #5B6570; }
        </style></head><body>\(html)</body></html>
        """
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        /// Only our own page loads in place. A link the reader clicks opens in their browser,
        /// and anything else the email tries (a redirect, a form) is stopped.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = action.request.url
            if action.navigationType == .linkActivated, let url {
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                return .cancel
            }
            return (url == nil || url?.scheme == "about") ? .allow : .cancel
        }
    }
}
