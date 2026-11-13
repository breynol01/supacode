import ComposableArchitecture
import Foundation

/// Looks up which registered Obsidian vault, if any, owns a file, so the files
/// inspector can hand vault notes to Obsidian instead of a code editor.
public nonisolated struct ObsidianVaultClient: Sendable {
  /// Root of the registered vault containing `url`, or `nil`. Reads Obsidian's
  /// own vault registry off the main actor.
  public var vaultRoot: @Sendable (_ url: URL) async -> URL?

  public init(vaultRoot: @escaping @Sendable (_ url: URL) async -> URL?) {
    self.vaultRoot = vaultRoot
  }
}

nonisolated extension ObsidianVaultClient: DependencyKey {
  public static let liveValue = ObsidianVaultClient { url in
    ObsidianVaults.vaultRoot(containing: url, registeredRoots: ObsidianVaults.loadRegisteredRoots())
  }

  public static let testValue = ObsidianVaultClient { _ in nil }
}

nonisolated extension DependencyValues {
  public var obsidianVaultClient: ObsidianVaultClient {
    get { self[ObsidianVaultClient.self] }
    set { self[ObsidianVaultClient.self] = newValue }
  }
}

/// Pure vault-matching logic behind `ObsidianVaultClient`.
///
/// Only vaults Obsidian has registered count. A folder that merely contains
/// `.obsidian/` (a git worktree of a vault, say) is unknown to Obsidian, and
/// `obsidian://open?path=` fails for it, so those keep the normal open chain.
public nonisolated enum ObsidianVaults {
  /// File types Obsidian owns. Images, PDFs, and configs inside a vault keep
  /// their usual apps.
  public static let noteExtensions: Set<String> = ["md", "canvas", "base"]

  public static func isNote(_ url: URL) -> Bool {
    noteExtensions.contains(url.pathExtension.lowercased())
  }

  /// Obsidian's vault registry, `~/Library/Application Support/obsidian/obsidian.json`.
  public static var configURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/obsidian/obsidian.json")
  }

  /// Registered vault roots, or `[]` when Obsidian has never run or the file
  /// is unreadable.
  public static func loadRegisteredRoots(configURL: URL = configURL) -> [URL] {
    guard let data = try? Data(contentsOf: configURL) else { return [] }
    return registeredRoots(fromConfig: data)
  }

  /// Parses the `vaults` map (`{id: {path, ts, open?}}`), ignoring entries
  /// without a path.
  public static func registeredRoots(fromConfig data: Data) -> [URL] {
    struct Config: Decodable {
      struct Vault: Decodable { let path: String? }
      let vaults: [String: Vault]?
    }
    guard let config = try? JSONDecoder().decode(Config.self, from: data) else { return [] }
    return (config.vaults ?? [:]).values.compactMap { vault in
      vault.path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
  }

  /// The deepest registered root that is `url` or one of its ancestors, so a
  /// vault nested inside another resolves to the inner one.
  public static func vaultRoot(containing url: URL, registeredRoots: [URL]) -> URL? {
    let path = normalizedPath(url)
    return
      registeredRoots
      .filter { root in
        let rootPath = normalizedPath(root)
        return path == rootPath || path.hasPrefix(rootPath + "/")
      }
      .max { normalizedPath($0).count < normalizedPath($1).count }
  }

  private static func normalizedPath(_ url: URL) -> String {
    var path = url.standardizedFileURL.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
}
