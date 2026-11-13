import Foundation
import Testing

@testable import SupacodeSettingsShared

struct ObsidianVaultsTests {
  private let roots = [
    URL(fileURLWithPath: "/Users/me/Obsidian/Dark Swan Productions", isDirectory: true),
    URL(fileURLWithPath: "/Users/me/Obsidian/The Cove", isDirectory: true),
    URL(fileURLWithPath: "/Users/me/Obsidian/The Cove/Nested Vault", isDirectory: true),
  ]

  @Test func parsesRegisteredVaultPaths() {
    let json = """
      {"vaults":{
        "a":{"path":"/Users/me/Obsidian/The Cove","ts":1},
        "b":{"path":"/Users/me/Obsidian/Tantalus","ts":2,"open":true},
        "c":{"ts":3}
      }}
      """
    let parsed = ObsidianVaults.registeredRoots(fromConfig: Data(json.utf8)).map { $0.path(percentEncoded: false) }
    #expect(Set(parsed) == ["/Users/me/Obsidian/The Cove/", "/Users/me/Obsidian/Tantalus/"])
  }

  @Test func malformedOrEmptyConfigYieldsNoVaults() {
    #expect(ObsidianVaults.registeredRoots(fromConfig: Data("not json".utf8)).isEmpty)
    #expect(ObsidianVaults.registeredRoots(fromConfig: Data("{}".utf8)).isEmpty)
  }

  @Test func missingConfigFileYieldsNoVaults() {
    let missing = URL(fileURLWithPath: "/tmp/no-such-obsidian-\(UUID().uuidString).json")
    #expect(ObsidianVaults.loadRegisteredRoots(configURL: missing).isEmpty)
  }

  @Test func fileInsideVaultResolvesToItsRoot() {
    let file = URL(fileURLWithPath: "/Users/me/Obsidian/Dark Swan Productions/Projects/Plan.md")
    #expect(ObsidianVaults.vaultRoot(containing: file, registeredRoots: roots) == roots[0])
  }

  @Test func vaultRootItselfResolves() {
    let root = URL(fileURLWithPath: "/Users/me/Obsidian/The Cove")
    #expect(ObsidianVaults.vaultRoot(containing: root, registeredRoots: roots) == roots[1])
  }

  @Test func nestedVaultWinsOverOuterVault() {
    let file = URL(fileURLWithPath: "/Users/me/Obsidian/The Cove/Nested Vault/Note.md")
    #expect(ObsidianVaults.vaultRoot(containing: file, registeredRoots: roots) == roots[2])
  }

  @Test func siblingWithSharedPrefixDoesNotMatch() {
    // "The Cove Archive" shares a string prefix with "The Cove" but is not inside it.
    let file = URL(fileURLWithPath: "/Users/me/Obsidian/The Cove Archive/Note.md")
    #expect(ObsidianVaults.vaultRoot(containing: file, registeredRoots: roots) == nil)
  }

  @Test func gitWorktreeOfVaultIsNotAVault() {
    // A Supacode worktree checkout is unknown to Obsidian, so it must not match.
    let file = URL(fileURLWithPath: "/Users/me/.supacode/repos/The Cove/branch/Note.md")
    #expect(ObsidianVaults.vaultRoot(containing: file, registeredRoots: roots) == nil)
  }

  @Test func noteExtensionsAreCaseInsensitive() {
    #expect(ObsidianVaults.isNote(URL(fileURLWithPath: "/v/a.md")))
    #expect(ObsidianVaults.isNote(URL(fileURLWithPath: "/v/a.MD")))
    #expect(ObsidianVaults.isNote(URL(fileURLWithPath: "/v/board.canvas")))
    #expect(ObsidianVaults.isNote(URL(fileURLWithPath: "/v/table.base")))
    #expect(!ObsidianVaults.isNote(URL(fileURLWithPath: "/v/image.png")))
    #expect(!ObsidianVaults.isNote(URL(fileURLWithPath: "/v/config.json")))
    #expect(!ObsidianVaults.isNote(URL(fileURLWithPath: "/v/README")))
  }

  @Test func obsidianSchemeURLStrictlyEncodesPath() {
    let url = OpenWorktreeAction.obsidian.urlSchemeTarget(forPath: "/Users/me/Dark Swan/a&b+c#d=e?.md")
    #expect(url?.absoluteString == "obsidian://open?path=/Users/me/Dark%20Swan/a%26b%2Bc%23d%3De%3F.md")
  }

  @Test func otherEditorsHaveNoSchemeURL() {
    #expect(OpenWorktreeAction.xcode.urlSchemeTarget(forPath: "/tmp/a.swift") == nil)
    #expect(OpenWorktreeAction.vscode.urlSchemeTarget(forPath: "/tmp/a.md") == nil)
  }

  @Test func obsidianIsAFileEditorButNeverTheAutomaticDefault() {
    #expect(OpenWorktreeAction.obsidian.canOpenFiles)
    #expect(OpenWorktreeAction.obsidian.bundleIdentifier == "md.obsidian")
    #expect(OpenWorktreeAction.obsidian.settingsID == "obsidian")
    #expect(OpenWorktreeAction.menuOrder.contains(.obsidian))
    // Code repos must not silently switch their default editor to Obsidian.
    #expect(!OpenWorktreeAction.defaultPriority.contains(.obsidian))
  }
}
