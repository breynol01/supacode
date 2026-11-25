import Foundation
import Testing

@testable import supacode

struct BrowserWebAuthnProbeTests {
  @Test func parseAcceptsCreateAndGet() {
    #expect(BrowserWebAuthnProbe.parse(["kind": "create"]) == .create)
    #expect(BrowserWebAuthnProbe.parse(["kind": "get"]) == .get)
  }

  @Test func parseRejectsUnexpectedBodies() {
    #expect(BrowserWebAuthnProbe.parse(["kind": "delete"]) == nil)
    #expect(BrowserWebAuthnProbe.parse(["kind": 1]) == nil)
    #expect(BrowserWebAuthnProbe.parse("create") == nil)
    #expect(BrowserWebAuthnProbe.parse([String: Any]()) == nil)
  }

  @Test func bannerSurvivesNavigationWithinTheSameHost() {
    let banner = URL(string: "https://github.com/login")
    let current = URL(string: "https://GitHub.com/sessions/two-factor")
    #expect(!BrowserWebAuthnProbe.shouldClear(banner: banner, current: current))
  }

  @Test func bannerClearsWhenLeavingTheHost() {
    let banner = URL(string: "https://github.com/login")
    #expect(
      BrowserWebAuthnProbe.shouldClear(banner: banner, current: URL(string: "https://example.com")))
    #expect(BrowserWebAuthnProbe.shouldClear(banner: banner, current: nil))
  }

  @Test func noBannerNeverClears() {
    #expect(
      !BrowserWebAuthnProbe.shouldClear(banner: nil, current: URL(string: "https://example.com")))
  }

  @Test func scriptTargetsTheRegisteredHandler() {
    #expect(
      BrowserWebAuthnProbe.source.contains("messageHandlers?.\(BrowserWebAuthnProbe.handlerName)"))
    #expect(BrowserWebAuthnProbe.source.contains(#"options.mediation !== "conditional""#))
  }
}
