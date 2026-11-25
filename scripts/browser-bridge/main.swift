// Drives the Chrome half of the browser-pane sign-in bridge end to end against
// the real Chrome, with no user input: popup launch, window identification,
// URL tracking, Chrome's cookie write-back delay, and popup close. A local
// fake site stands in for the passkey login (it signs in by itself).
// Never touches the Keychain (rows are read without decryption).
// Run with scripts/browser-bridge/run-harness.sh.
import AppKit
import Foundation
import WebKit

@MainActor
enum Harness {
  static func run(port: Int) async -> Int32 {
    let start = URL(string: "http://localhost:\(port)/login")!
    let profile = ChromeCookieStore.lastUsedProfile()
    let hosts = ChromeCookieStore.hostKeys(for: "localhost")
    print("profile=\(profile)")
    let opened = Date.now
    guard let window = await ChromePopup.open(start, profile: profile) else {
      print("FAIL popup window not identified (Automation access to Chrome?)")
      return 1
    }
    print("ok   popup window=\(window) after \(elapsed(opened))")
    var signedInAt: Date?
    var lastURL: URL?
    for _ in 0..<30 {
      try? await Task.sleep(for: .seconds(1))
      guard let lookup = ChromePopup.currentURL(ofWindow: window) else { continue }
      guard let url = lookup else {
        print("FAIL popup closed unexpectedly")
        return 1
      }
      if url != lastURL { print("     popup at \(url.absoluteString) (\(elapsed(opened)))") }
      lastURL = url
      if url.path() == "/home" {
        signedInAt = .now
        break
      }
    }
    guard let signedInAt else {
      print("FAIL popup never reached /home")
      return 1
    }
    print("ok   signed-in page seen after \(elapsed(opened))")
    // Same rule as BrowserPasskeyBridge.isSettled: a fresh row, or a full
    // write-back period (an already signed-in profile writes nothing new).
    let threshold = ChromeCookieStore.chromeTime(from: signedInAt.addingTimeInterval(-3))
    let window33: TimeInterval = 33
    var settledBy: String?
    var hasSession = false
    while settledBy == nil {
      do {
        let rows = try ChromeCookieStore.rows(forHosts: hosts, profile: profile, decrypting: false)
        hasSession = rows.contains { $0.name == "harness_session" }
        if rows.contains(where: { $0.lastUpdateUTC >= threshold }) {
          settledBy = "fresh write"
        } else if Date.now.timeIntervalSince(signedInAt) >= window33 {
          settledBy = "write-back window"
        }
      } catch {
        print("FAIL cookie read: \(error)")
        return 1
      }
      if settledBy == nil { try? await Task.sleep(for: .seconds(1)) }
    }
    let waited = String(format: "%.1fs", Date.now.timeIntervalSince(signedInAt))
    guard hasSession else {
      print("FAIL settled by \(settledBy!) after \(waited) but harness_session is not on disk")
      return 1
    }
    print("ok   settled by \(settledBy!) after \(waited); harness_session on disk")
    ChromePopup.close(window: window)
    try? await Task.sleep(for: .seconds(1))
    let gone = ChromePopup.currentURL(ofWindow: window).map { $0 == nil } ?? false
    print(gone ? "ok   popup closed" : "FAIL popup still open")
    guard gone else { return 1 }
    return await checkWebView(port: port)
  }

  /// The pane half: cookies built the way the bridge builds them must reach
  /// the site from a WKWebView (host-only domain, HttpOnly, SameSite).
  static func checkWebView(port: Int) async -> Int32 {
    let row = ChromeCookieStore.Row(
      hostKey: "localhost", name: "harness_check", value: "v123", path: "/",
      expiresUTC: ChromeCookieStore.chromeTime(from: .now.addingTimeInterval(3600)),
      hasExpires: true,
      isSecure: false, isHTTPOnly: true, sameSite: 1)
    guard let cookie = ChromeCookieStore.cookie(from: row) else {
      print("FAIL cookie(from:) returned nil")
      return 1
    }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration)
    await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
    let loader = Loader()
    view.navigationDelegate = loader
    view.load(URLRequest(url: URL(string: "http://localhost:\(port)/whoami")!))
    await loader.finished()
    let body = (try? await view.evaluateJavaScript("document.body.innerText")) as? String ?? ""
    let ok = body.contains("harness_check=v123")
    print(ok ? "ok   WKWebView sent the imported cookie" : "FAIL WKWebView sent: \(body)")
    return ok ? 0 : 1
  }

  static func elapsed(_ since: Date) -> String {
    String(format: "%.1fs", Date.now.timeIntervalSince(since))
  }
}

@MainActor
final class Loader: NSObject, WKNavigationDelegate {
  private var continuation: CheckedContinuation<Void, Never>?
  func finished() async { await withCheckedContinuation { continuation = $0 } }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    continuation?.resume()
    continuation = nil
  }
}

let port = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 8766
let app = NSApplication.shared
Task { @MainActor in
  exit(await Harness.run(port: port))
}
app.run()
