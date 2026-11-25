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
    let toolbar = browserToolbar
    let proxy = BrowserScriptMessageProxy { [weak toolbar] message in
      guard let toolbar, let kind = BrowserWebAuthnProbe.parse(message.body) else { return }
      toolbar.reportPasskey(kind, at: message.webView?.url ?? toolbar.currentURL)
    }
    configuration.userContentController.addUserScript(BrowserWebAuthnProbe.makeUserScript())
    configuration.userContentController.add(proxy, name: BrowserWebAuthnProbe.handlerName)
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
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: BrowserWebAuthnProbe.handlerName)
    webView.stopLoading()
    webView.removeFromSuperview()
    self.webView = nil
    browserToolbar.webView = nil
    browserToolbar.passkeyRequestURL = nil
    browserToolbar.cancelSignIn()
  }

  func snapshot() -> ContentSnapshot {
    ContentSnapshot(id: id, state: .browser(BrowserContentState(url: webView?.url ?? state.url)))
  }

  private func observe(_ view: WKWebView) {
    let chrome = browserChrome
    let toolbar = browserToolbar
    observations = [
      view.observe(\.title, options: [.initial, .new]) { view, _ in
        MainActor.assumeIsolated {
          chrome.reportedTitle = view.title.flatMap { $0.isEmpty ? nil : $0 }
        }
      },
      view.observe(\.isLoading, options: [.initial, .new]) { view, _ in
        MainActor.assumeIsolated { chrome.isWorking = view.isLoading }
      },
      view.observe(\.url, options: [.initial, .new]) { view, _ in
        MainActor.assumeIsolated {
          toolbar.currentURL = view.url
          let banner = toolbar.passkeyRequestURL
          if BrowserWebAuthnProbe.shouldClear(banner: banner, current: view.url) {
            toolbar.passkeyRequestURL = nil
          }
        }
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
  /// Set when the page asked for a passkey the web view cannot provide.
  var passkeyRequestURL: URL?
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

  /// Hands the page to the system default browser, where passkeys and
  /// password-manager extensions work.
  func openInDefaultBrowser() {
    guard let url = passkeyRequestURL ?? webView?.url ?? currentURL else { return }
    NSWorkspace.shared.open(url)
    passkeyRequestURL = nil
  }

  // MARK: Chrome sign-in bridge

  enum SignIn: Equatable {
    case idle
    /// The Chrome popup is open on `start`; `popupWindow` is its AppleScript id
    /// when Automation access allowed identifying it.
    case waiting(start: URL, popupWindow: Int?)
    case importing
    case failed(String)
  }

  var signIn: SignIn = .idle {
    didSet {
      guard signIn != oldValue else { return }
      BrowserBridgeTrace.record("state \(BrowserPasskeyBridge.describe(signIn))")
      // Supacode sits in the background while the popup is up; App Nap would
      // stretch the 1s polls to 10s+, so opt out while a sign-in is running.
      let busy =
        switch signIn {
        case .waiting, .importing: true
        case .idle, .failed: false
        }
      if busy, napActivity == nil {
        napActivity = ProcessInfo.processInfo.beginActivity(
          options: [.userInitiated], reason: "Browser pane passkey sign-in")
      } else if !busy, let activity = napActivity {
        ProcessInfo.processInfo.endActivity(activity)
        napActivity = nil
      }
    }
  }
  private var napActivity: (any NSObjectProtocol)?
  /// Hosts whose Chrome sign-in was imported; their availability checks no
  /// longer raise the banner (an explicit create/get still does).
  private var importedHosts: Set<String> = []

  func reportPasskey(_ kind: BrowserWebAuthnProbe.Kind, at url: URL?) {
    if kind == .detect, let host = url?.host()?.lowercased(), importedHosts.contains(host) {
      return
    }
    if passkeyRequestURL == nil {
      BrowserBridgeTrace.record("banner raised kind=\(kind.rawValue) host=\(url?.host() ?? "-")")
    }
    passkeyRequestURL = url
  }
  private var popupURL: URL?
  /// When the popup last changed page; Chrome's cookie write-back for the
  /// sign-in lands after this.
  private var popupNavigatedAt = Date.distantPast
  private var signInTask: Task<Void, Never>?

  /// Opens the page in a small Chrome app window where 1Password and the
  /// system passkey sheet work, then carries the resulting cookies back.
  func signInWithChrome() {
    guard let start = passkeyRequestURL ?? webView?.url ?? currentURL else { return }
    signInTask?.cancel()
    popupURL = nil
    popupNavigatedAt = .now
    signIn = .waiting(start: start, popupWindow: nil)
    let profile = ChromeCookieStore.lastUsedProfile()
    BrowserBridgeTrace.record(
      "sign-in start url=\(BrowserPasskeyBridge.redacted(start)) profile=\(profile)")
    signInTask = Task { [weak self] in
      let window = await ChromePopup.open(start, profile: profile)
      BrowserBridgeTrace.record(
        "popup opened window=\(window.map(String.init) ?? "unidentified (no Automation access?)")")
      guard let self, !Task.isCancelled, case .waiting = self.signIn else { return }
      self.signIn = .waiting(start: start, popupWindow: window)
      guard let window else { return }
      await self.watchPopup(window, start: start, profile: profile)
    }
  }

  /// Polls the popup: it finishes on its own once the popup lands on a
  /// signed-in page of the same site, or when the user closes it.
  private func watchPopup(_ window: Int, start: URL, profile: String) async {
    var settledURL: URL?
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(1))
      guard case .waiting = signIn else { return }
      guard let lookup = ChromePopup.currentURL(ofWindow: window) else { continue }
      guard let url = lookup else {
        BrowserBridgeTrace.record("popup closed by user")
        await importCookies(start: start, profile: profile, closing: nil)
        return
      }
      if url != popupURL {
        popupNavigatedAt = .now
        BrowserBridgeTrace.record("popup at \(BrowserPasskeyBridge.redacted(url))")
      }
      popupURL = url
      if BrowserPasskeyBridge.looksSignedIn(start: start, current: url) {
        // One more tick on the same URL rides out redirect chains.
        if settledURL == url {
          BrowserBridgeTrace.record("popup looks signed in")
          await importCookies(start: start, profile: profile, closing: window)
          return
        }
        settledURL = url
      } else {
        settledURL = nil
      }
    }
  }

  /// "Done" in the banner: import now, whatever the popup shows.
  func finishSignIn() {
    guard case .waiting(let start, let window) = signIn else { return }
    BrowserBridgeTrace.record("done clicked")
    signInTask?.cancel()
    let profile = ChromeCookieStore.lastUsedProfile()
    signInTask = Task { [weak self] in
      await self?.importCookies(start: start, profile: profile, closing: window)
    }
  }

  func cancelSignIn() {
    if signIn != .idle { BrowserBridgeTrace.record("sign-in cancelled") }
    signInTask?.cancel()
    signInTask = nil
    signIn = .idle
  }

  private func importCookies(start: URL, profile: String, closing window: Int?) async {
    signIn = .importing
    var hosts = ChromeCookieStore.hostKeys(for: start.host() ?? "")
    if let popupHost = popupURL?.host(), BrowserPasskeyBridge.isSameSite(start, popupURL) {
      hosts.formUnion(ChromeCookieStore.hostKeys(for: popupHost))
    }
    // Chrome persists cookie changes in batches, so wait until its file holds
    // a write from after the popup's last navigation (the signed-in page), or
    // until a full write-back period has passed since then (nothing was pending).
    let landedAt = popupNavigatedAt
    let threshold = ChromeCookieStore.chromeTime(from: landedAt.addingTimeInterval(-3))
    var rows: [ChromeCookieStore.Row] = []
    while true {
      let result = await Task.detached { [hosts] in
        Result { try ChromeCookieStore.rows(forHosts: hosts, profile: profile) }
      }.value
      switch result {
      case .failure(let error):
        BrowserBridgeTrace.record("cookie read failed: \(error)")
        signIn = .failed(BrowserPasskeyBridge.message(for: error))
        return
      case .success(let read):
        rows = read
      }
      let settled = BrowserPasskeyBridge.isSettled(rows, after: threshold, landedAt: landedAt)
      BrowserBridgeTrace.record(
        "chrome rows=\(rows.count) settled=\(settled) newest=\(BrowserPasskeyBridge.newest(rows))")
      if settled { break }
      guard !Task.isCancelled else { return }
      try? await Task.sleep(for: .seconds(1.5))
    }
    let cookies = rows.compactMap { ChromeCookieStore.cookie(from: $0) }
    BrowserBridgeTrace.record(
      "importing \(cookies.count) cookies: \(cookies.map(\.name).sorted().joined(separator: ","))")
    guard !cookies.isEmpty else {
      signIn = .failed(
        "Chrome has no sign-in for \(start.host() ?? "this site") yet. Finish signing in there.")
      return
    }
    guard let webView else {
      signIn = .idle
      return
    }
    let store = webView.configuration.websiteDataStore.httpCookieStore
    for cookie in cookies {
      await store.setCookie(cookie)
    }
    let stored = await store.allCookies().filter { hosts.contains($0.domain.lowercased()) }
    BrowserBridgeTrace.record("pane now holds \(stored.count) cookies for the site")
    if let window { ChromePopup.close(window: window) }
    let destination = BrowserPasskeyBridge.isSameSite(start, popupURL) ? popupURL ?? start : start
    BrowserBridgeTrace.record("reloading pane at \(BrowserPasskeyBridge.redacted(destination))")
    webView.load(URLRequest(url: destination))
    importedHosts.insert((start.host() ?? "").lowercased())
    if let host = destination.host() { importedHosts.insert(host.lowercased()) }
    passkeyRequestURL = nil
    signIn = .idle
    NSApp.activate()
  }
}

/// Pure decisions behind the Chrome sign-in bridge.
nonisolated enum BrowserPasskeyBridge {
  static func describe(_ state: BrowserToolbar.SignIn) -> String {
    switch state {
    case .idle: "idle"
    case .waiting(_, let window): "waiting popup=\(window.map(String.init) ?? "-")"
    case .importing: "importing"
    case .failed(let reason): "failed: \(reason)"
    }
  }

  private static let authPathMarkers = [
    "login", "logon", "signin", "sign-in", "sign_in", "session", "auth", "sso", "saml",
    "two-factor", "2fa", "mfa", "webauthn", "passkey", "challenge", "verify", "consent",
  ]

  /// Chrome's cookie write-back period (30s) plus slack. Once this much time
  /// has passed since the signed-in page, everything Chrome held then is on disk.
  static let writeBackWindow: TimeInterval = 33

  /// Chrome's file reflects the sign-in: it holds a write from after the
  /// signed-in page, or a full write-back period has passed (an already
  /// signed-in profile may write nothing new).
  static func isSettled(
    _ rows: [ChromeCookieStore.Row], after threshold: Int64, landedAt: Date, now: Date = .now
  ) -> Bool {
    rows.contains { $0.lastUpdateUTC >= threshold }
      || now.timeIntervalSince(landedAt) >= writeBackWindow
  }

  static func newest(_ rows: [ChromeCookieStore.Row]) -> String {
    guard let latest = rows.map(\.lastUpdateUTC).max(),
      let date = ChromeCookieStore.date(fromChromeTime: latest)
    else { return "-" }
    return date.formatted(.iso8601.time(includingFractionalSeconds: false))
  }

  /// Scheme, host and path only: queries can carry tokens.
  static func redacted(_ url: URL) -> String {
    "\(url.scheme ?? "")://\(url.host() ?? "")\(url.path())"
  }

  static func isSameSite(_ lhs: URL?, _ rhs: URL?) -> Bool {
    guard let lhs = lhs?.host(), let rhs = rhs?.host() else { return false }
    return !ChromeCookieStore.hostKeys(for: lhs).isDisjoint(
      with: ChromeCookieStore.hostKeys(for: rhs))
  }

  /// The popup has left the sign-in flow: same site, a different page, and no
  /// sign-in marker in its path.
  static func looksSignedIn(start: URL, current: URL) -> Bool {
    guard isSameSite(start, current) else { return false }
    let path = current.path().lowercased()
    guard path != start.path().lowercased() else { return false }
    return !authPathMarkers.contains { path.contains($0) }
  }

  static func message(for error: Error) -> String {
    switch error as? ChromeCookieStore.Failure {
    case .keychainDenied:
      "Supacode needs Keychain access to \"Chrome Safe Storage\" to bring the sign-in back."
    case .cookieFileMissing, .chromeNotInstalled:
      "Couldn't find Chrome's cookies for your last-used profile."
    case .database(let detail):
      "Couldn't read Chrome's cookies (\(detail))."
    case nil:
      error.localizedDescription
    }
  }
}

/// Turns typed text into a URL: a scheme passes through, a bare host gets
/// https, and anything else becomes a search.
nonisolated enum BrowserURL {
  static func resolve(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), let scheme = url.scheme,
      ["http", "https", "file", "about"].contains(scheme)
    {
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

  private var urlRow: some View {
    HStack(spacing: 6) {
      Button {
        toolbar.webView?.goBack()
      } label: {
        Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly)
      }
      .disabled(!toolbar.canGoBack)
      .help("Back")
      Button {
        toolbar.webView?.goForward()
      } label: {
        Label("Forward", systemImage: "chevron.right").labelStyle(.iconOnly)
      }
      .disabled(!toolbar.canGoForward)
      .help("Forward")
      Button {
        toolbar.webView?.reload()
      } label: {
        Label("Reload", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
      }
      .help("Reload")
      TextField("Search or enter address", text: $text)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .focused($isEditing)
        .onSubmit {
          toolbar.load(text)
          isEditing = false
        }
      Button {
        toolbar.openInDefaultBrowser()
      } label: {
        Label("Open in Default Browser", systemImage: "safari").labelStyle(.iconOnly)
      }
      .help("Open in Default Browser (passkeys and password managers work there)")
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
  }

  var body: some View {
    VStack(spacing: 0) {
      urlRow
      if toolbar.passkeyRequestURL != nil || toolbar.signIn != .idle {
        BrowserPasskeyBanner(toolbar: toolbar)
      }
    }
    .onAppear { text = toolbar.currentURL?.absoluteString ?? "" }
    .onChange(of: toolbar.currentURL) { _, url in
      guard !isEditing else { return }
      text = url?.absoluteString ?? ""
    }
  }
}

/// Shown when the page asked for a passkey. The web view cannot reach the
/// system passkey sheet, so the sign-in runs in a Chrome popup and its cookies
/// come back to the pane.
private struct BrowserPasskeyBanner: View {
  let toolbar: BrowserToolbar

  var body: some View {
    HStack(spacing: 8) {
      switch toolbar.signIn {
      case .idle:
        message("This site uses passkeys, which Supacode's browser can't reach directly.")
        Spacer(minLength: 8)
        if ChromePopup.isInstalled {
          Button("Sign in with Chrome") { toolbar.signInWithChrome() }
            .help(
              "Sign in through a Chrome popup (passkeys and 1Password work there), then continue here"
            )
        } else {
          Button("Open in Browser") { toolbar.openInDefaultBrowser() }
            .help("Open this page in your default browser to sign in with a passkey")
        }
        dismissButton { toolbar.passkeyRequestURL = nil }
      case .waiting:
        ProgressView().controlSize(.small)
        message("Finish signing in in the Chrome window. This page continues once you're in.")
        Spacer(minLength: 8)
        Button("Done") { toolbar.finishSignIn() }
          .help("Bring the Chrome sign-in into this page now")
        dismissButton { toolbar.cancelSignIn() }
      case .importing:
        ProgressView().controlSize(.small)
        message("Waiting for Chrome to save your sign-in, then bringing it over…")
        Spacer(minLength: 8)
      case .failed(let reason):
        message(reason)
        Spacer(minLength: 8)
        Button("Try Again") { toolbar.signInWithChrome() }
          .help("Reopen the Chrome sign-in popup")
        dismissButton { toolbar.cancelSignIn() }
      }
    }
    .controlSize(.small)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(.bar)
  }

  private func message(_ text: String) -> some View {
    Label {
      Text(text)
    } icon: {
      Image(systemName: "person.badge.key")
    }
    .font(.callout)
    .foregroundStyle(.secondary)
  }

  private func dismissButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly)
    }
    .buttonStyle(.borderless)
    .help("Dismiss")
  }
}
