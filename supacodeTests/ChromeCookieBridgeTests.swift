import CommonCrypto
import CryptoKit
import Foundation
import Testing

@testable import supacode

struct ChromeCookieBridgeTests {
  @Test func hostKeysCoverHostAndParentDomains() {
    #expect(
      ChromeCookieStore.hostKeys(for: "Accounts.Example.com")
        == ["accounts.example.com", ".accounts.example.com", "example.com", ".example.com"])
    #expect(ChromeCookieStore.hostKeys(for: "localhost") == ["localhost", ".localhost"])
  }

  @Test func chromeTimeConvertsFrom1601Epoch() {
    // 2026-01-01T00:00:00Z
    let unix: Double = 1_767_225_600
    let chrome = Int64((unix + 11_644_473_600) * 1_000_000)
    #expect(ChromeCookieStore.date(fromChromeTime: chrome) == Date(timeIntervalSince1970: unix))
    #expect(ChromeCookieStore.date(fromChromeTime: 0) == nil)
  }

  @Test func decryptsV10ValuesAndDropsTheHostDigest() throws {
    let key = ChromeCookieStore.deriveKey(password: Data("peanuts".utf8))
    let digest = Data(SHA256.hash(data: Data(".github.com".utf8)))
    let plaintext = digest + Data("session-value".utf8)
    let ciphertext = try #require(
      ChromeCookieStore.aes128CBC(plaintext, key: key, operation: CCOperation(kCCEncrypt)))
    let encrypted = Data("v10".utf8) + ciphertext
    #expect(ChromeCookieStore.decrypt(encrypted, key: key, schemaVersion: 24) == "session-value")

    let legacy =
      Data("v10".utf8)
      + (try #require(
        ChromeCookieStore.aes128CBC(Data("old".utf8), key: key, operation: CCOperation(kCCEncrypt))))
    #expect(ChromeCookieStore.decrypt(legacy, key: key, schemaVersion: 23) == "old")
    #expect(ChromeCookieStore.decrypt(Data("v11xyz".utf8), key: key, schemaVersion: 24) == nil)
  }

  @Test func rowMapsToCookieAndSkipsExpired() throws {
    let now = Date(timeIntervalSince1970: 1_767_225_600)
    let future = Int64((now.timeIntervalSince1970 + 3600 + 11_644_473_600) * 1_000_000)
    let row = ChromeCookieStore.Row(
      hostKey: ".github.com", name: "user_session", value: "abc", path: "/",
      expiresUTC: future, hasExpires: true, isSecure: true, isHTTPOnly: true, sameSite: 1)
    let cookie = try #require(ChromeCookieStore.cookie(from: row, now: now))
    #expect(cookie.domain == ".github.com")
    #expect(cookie.isSecure)
    #expect(cookie.isHTTPOnly)
    #expect(cookie.sameSitePolicy == .sameSiteLax)

    var expired = row
    expired.expiresUTC = Int64((now.timeIntervalSince1970 - 60 + 11_644_473_600) * 1_000_000)
    #expect(ChromeCookieStore.cookie(from: expired, now: now) == nil)

    var session = row
    session.hasExpires = false
    #expect(ChromeCookieStore.cookie(from: session, now: now)?.isSessionOnly == true)
  }

  @Test func signedInOnceThePopupLeavesTheAuthFlow() throws {
    let start = try #require(URL(string: "https://github.com/login"))
    let check = { (text: String) in
      BrowserPasskeyBridge.looksSignedIn(start: start, current: URL(string: text)!)
    }
    #expect(check("https://github.com/"))
    #expect(check("https://github.com/breynol01"))
    #expect(!check("https://github.com/login"))
    #expect(!check("https://github.com/sessions/two-factor/webauthn"))
    #expect(!check("https://accounts.google.com/"))
  }

  @Test func sameSiteMatchesSharedParentDomain() {
    #expect(
      BrowserPasskeyBridge.isSameSite(
        URL(string: "https://login.example.com/x"), URL(string: "https://app.example.com/")))
    #expect(
      !BrowserPasskeyBridge.isSameSite(
        URL(string: "https://example.com"), URL(string: "https://other.com")))
    #expect(!BrowserPasskeyBridge.isSameSite(nil, URL(string: "https://other.com")))
  }

  @MainActor
  @Test func availabilityCheckRaisesTheBanner() throws {
    let toolbar = BrowserToolbar(contentID: ContentID())
    let url = try #require(URL(string: "https://github.com/"))
    toolbar.reportPasskey(.detect, at: url)
    #expect(toolbar.passkeyRequestURL == url)
  }
}
