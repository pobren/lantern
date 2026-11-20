// Shows an email the way its sender laid it out, safely: no scripts, nothing it can submit, links open in your
// browser, and pictures from the web load only when you allow them (Settings, or the button on the email).

import SwiftUI
import WebKit

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

struct EmailWebView: PlatformViewRepresentable {
    let html: String
    let remoteImages: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeView(_ context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()          // no cookies kept between emails
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        #endif
        return view
    }

    private func show(_ view: WKWebView, _ context: Context) {
        let page = Self.wrap(html, remoteImages: remoteImages)
        guard context.coordinator.loaded != page else { return }
        context.coordinator.loaded = page
        view.loadHTMLString(page, baseURL: nil)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeView(context) }
    func updateNSView(_ view: WKWebView, context: Context) { show(view, context) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeView(context) }
    func updateUIView(_ view: WKWebView, context: Context) { show(view, context) }
    #endif

    /// Wraps the email in a page with a strict content policy: inline styles and data: pictures always,
    /// web pictures, styles and fonts only when allowed, and never scripts, frames, forms or plugins.
    /// Emails are drawn on white, as their senders designed them, even in dark mode.
    /// Plain text as email HTML, for when only the text could be fetched.
    static func plain(_ text: String) -> String {
        let safe = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return "<div class=\"lantern-text\">" + safe + "</div>"
    }

    static func wrap(_ html: String, remoteImages: Bool) -> String {
        let web = remoteImages ? " https: http:" : ""
        let policy = "default-src 'none'; img-src data:\(web); style-src 'unsafe-inline'\(web); font-src data:\(web); media-src data:\(web); form-action 'none'; frame-src 'none'; script-src 'none'"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light only">
        <style>
          html { -webkit-text-size-adjust: 100%; background: #fff; }
          body { margin: 0 !important; padding: 18px 12px 48px !important; background: #fff; font: \(Look.bodyPoints)px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; color: #16191D; word-wrap: break-word; overflow-wrap: anywhere; }
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
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    await UIApplication.shared.open(url)
                    #endif
                }
                return .cancel
            }
            return (url == nil || url?.scheme == "about") ? .allow : .cancel
        }
    }
}
