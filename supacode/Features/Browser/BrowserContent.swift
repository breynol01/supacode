import AppKit
import SwiftUI
import WebKit

/// Browser content backed by a `WKWebView`. Every browser tab shares the app's
/// default persistent website data store, so a sign-in in one worktree carries
/// to every other. A page has no session outside its view, so browsers never
/// hibernate; the URL is all a relaunch needs.
@MainActor
final class BrowserContent: TabContent {
  let id: ContentID
  let kind: ContentKind = .browser
  let browserChrome = BrowserTabChrome()
  private let browserToolbar: BrowserToolbar
  private var state: BrowserContentState
  private var webView: WKWebView?
  private var observations: [NSKeyValueObservation] = []

  var chrome: (any TabChrome)? { browserChrome }
  var toolbar: (any TabContentToolbar)? { browserToolbar }

  init(id: ContentID, initialState: BrowserContentState) {
    self.id = id
    self.state = initialState
    self.browserToolbar = BrowserToolbar(contentID: id)
  }

  nonisolated deinit {}

  var renderer: NSView? { webView }

  func startSession(at geometry: ContentGeometry) {
    guard webView == nil else { return }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.allowsBackForwardNavigationGestures = true
    view.allowsMagnification = true
    webView = view
    browserToolbar.webView = view
    observe(view)
    if let url = state.url {
      view.load(URLRequest(url: url))
    }
  }

  func hibernate() {
    tearDown()
  }

  func tearDown() {
    guard let webView else { return }
    state.url = webView.url ?? state.url
    observations.removeAll()
    webView.stopLoading()
    webView.removeFromSuperview()
    self.webView = nil
    browserToolbar.webView = nil
  }

  func snapshot() -> ContentSnapshot {
    ContentSnapshot(id: id, state: .browser(BrowserContentState(url: webView?.url ?? state.url)))
  }

  private func observe(_ view: WKWebView) {
    let chrome = browserChrome
    let toolbar = browserToolbar
    observations = [
      view.observe(\.title, options: [.initial, .new]) { view, _ in
        MainActor.assumeIsolated { chrome.reportedTitle = view.title.flatMap { $0.isEmpty ? nil : $0 } }
      },
      view.observe(\.isLoading, options: [.initial, .new]) { view, _ in
        MainActor.assumeIsolated { chrome.isWorking = view.isLoading }
      },
      view.observe(\.url, options: [.initial, .new]) { view, _ in
        MainActor.assumeIsolated { toolbar.currentURL = view.url }
      },
      view.observe(\.canGoBack, options: [.initial, .new]) { view, _ in
        MainActor.assumeIsolated { toolbar.canGoBack = view.canGoBack }
      },
      view.observe(\.canGoForward, options: [.initial, .new]) { view, _ in
        MainActor.assumeIsolated { toolbar.canGoForward = view.canGoForward }
      },
    ]
  }
}

@MainActor
@Observable
final class BrowserTabChrome: TabChrome {
  var isWorking = false
  var reportedTitle: String?
  var accessory: AnyView? { nil }
  var progress: TerminalTabProgressDisplay? { nil }
  var isReadOnly: Bool { false }

  nonisolated deinit {}
}

/// The docked URL bar: back, forward, reload, and an editable address.
@MainActor
@Observable
final class BrowserToolbar: TabContentToolbar {
  let contentID: ContentID
  // Weak: `BrowserContent` is the sole owner of the view.
  weak var webView: WKWebView?
  var currentURL: URL?
  var canGoBack = false
  var canGoForward = false

  init(contentID: ContentID) {
    self.contentID = contentID
  }

  nonisolated deinit {}

  var view: AnyView? {
    guard webView != nil else { return nil }
    return AnyView(BrowserURLBar(toolbar: self).id(contentID))
  }

  func load(_ text: String) {
    guard let url = BrowserURL.resolve(text) else { return }
    webView?.load(URLRequest(url: url))
  }
}

/// Turns typed text into a URL: a scheme passes through, a bare host gets
/// https, and anything else becomes a search.
nonisolated enum BrowserURL {
  static func resolve(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https", "file", "about"].contains(scheme) {
      return url
    }
    if !trimmed.contains(" "), trimmed.contains(".") || trimmed.hasPrefix("localhost") {
      return URL(string: "https://\(trimmed)")
    }
    var components = URLComponents(string: "https://duckduckgo.com/")
    components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
    return components?.url
  }
}

private struct BrowserURLBar: View {
  @Bindable var toolbar: BrowserToolbar
  @State private var text = ""
  @FocusState private var isEditing: Bool

  var body: some View {
    HStack(spacing: 6) {
      Button { toolbar.webView?.goBack() } label: { Image(systemName: "chevron.left") }
        .disabled(!toolbar.canGoBack)
        .help("Back")
      Button { toolbar.webView?.goForward() } label: { Image(systemName: "chevron.right") }
        .disabled(!toolbar.canGoForward)
        .help("Forward")
      Button { toolbar.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
        .help("Reload")
      TextField("Search or enter address", text: $text)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .focused($isEditing)
        .onSubmit {
          toolbar.load(text)
          isEditing = false
        }
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .onAppear { text = toolbar.currentURL?.absoluteString ?? "" }
    .onChange(of: toolbar.currentURL) { _, url in
      guard !isEditing else { return }
      text = url?.absoluteString ?? ""
    }
  }
}
