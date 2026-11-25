import Foundation
import WebKit

/// Detects pages asking for a passkey. WebKit disables WebAuthn in a third-party
/// `WKWebView` unless the app holds Apple's restricted Web Browser Public Key
/// Credential entitlement, so `navigator.credentials` rejects and the system
/// passkey sheet (and every credential provider, 1Password included) never
/// appears. The probe reports the attempt so the browser can offer to hand the
/// page to the default browser instead.
nonisolated enum BrowserWebAuthnProbe {
  enum Kind: String, Equatable, Sendable {
    case create
    case get
  }

  static let handlerName = "supacodeWebAuthn"

  /// Wraps `navigator.credentials.create`/`get`, reports modal public-key calls,
  /// then defers to the original so the page sees its usual rejection.
  /// Conditional mediation (passkey autofill a page arms on load) is skipped so
  /// merely visiting a sign-in page does not raise the banner.
  static let source = """
    (() => {
      const credentials = navigator.credentials;
      const handler = window.webkit?.messageHandlers?.\(handlerName);
      if (!credentials || !handler) return;
      for (const kind of ["create", "get"]) {
        const original = credentials[kind];
        if (typeof original !== "function") continue;
        credentials[kind] = function (options) {
          try {
            if (options && options.publicKey && options.mediation !== "conditional") {
              handler.postMessage({ kind });
            }
          } catch (_) {}
          return original.apply(this, arguments);
        };
      }
    })();
    """

  @MainActor
  static func makeUserScript() -> WKUserScript {
    WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
  }

  static func parse(_ body: Any) -> Kind? {
    guard let dictionary = body as? [String: Any], let raw = dictionary["kind"] as? String else {
      return nil
    }
    return Kind(rawValue: raw)
  }

  /// The banner belongs to the site that asked; leaving that host drops it.
  static func shouldClear(banner: URL?, current: URL?) -> Bool {
    guard let banner else { return false }
    guard let bannerHost = banner.host(), let currentHost = current?.host() else { return true }
    return bannerHost.lowercased() != currentHost.lowercased()
  }
}

/// Forwards script messages without the content controller retaining the
/// browser (it holds its handlers strongly).
@MainActor
final class BrowserScriptMessageProxy: NSObject, WKScriptMessageHandler {
  private let onMessage: @MainActor (WKScriptMessage) -> Void

  init(onMessage: @escaping @MainActor (WKScriptMessage) -> Void) {
    self.onMessage = onMessage
  }

  nonisolated deinit {}

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    onMessage(message)
  }
}
