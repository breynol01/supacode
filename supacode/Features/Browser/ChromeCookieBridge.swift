import AppKit
import CommonCrypto
import Foundation
import SQLite3

/// Reads a site's cookies out of Google Chrome so a sign-in finished there
/// (passkeys, 1Password) carries into a browser pane. Chrome on macOS stores
/// cookies in a per-profile SQLite file, each value AES-128-CBC encrypted with a
/// key derived from the "Chrome Safe Storage" Keychain item.
nonisolated enum ChromeCookieStore {
  enum Failure: Error, Equatable {
    case chromeNotInstalled
    case cookieFileMissing
    case keychainDenied(OSStatus)
    case database(String)
  }

  static let supportDirectory = URL.homeDirectory
    .appending(path: "Library/Application Support/Google/Chrome", directoryHint: .isDirectory)

  /// The profile Chrome opens by default ("Default" when Local State is unreadable).
  static func lastUsedProfile() -> String {
    let localState = supportDirectory.appending(path: "Local State")
    guard let data = try? Data(contentsOf: localState),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let profile = json["profile"] as? [String: Any],
      let lastUsed = profile["last_used"] as? String, !lastUsed.isEmpty
    else { return "Default" }
    return lastUsed
  }

  /// Cookie hosts a page on `host` can receive: the host and each parent
  /// domain down to two labels, with and without Chrome's leading dot.
  static func hostKeys(for host: String) -> Set<String> {
    var labels = host.lowercased().split(separator: ".").map(String.init)
    var keys: Set<String> = []
    while labels.count >= 2 {
      let domain = labels.joined(separator: ".")
      keys.insert(domain)
      keys.insert("." + domain)
      labels.removeFirst()
    }
    if keys.isEmpty, !host.isEmpty {
      keys = [host.lowercased(), "." + host.lowercased()]
    }
    return keys
  }

  /// Chrome timestamps are microseconds since 1601-01-01 UTC.
  static func date(fromChromeTime value: Int64) -> Date? {
    guard value > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(value) / 1_000_000 - 11_644_473_600)
  }

  static func deriveKey(password: Data) -> Data {
    var key = Data(count: kCCKeySizeAES128)
    let salt = Data("saltysalt".utf8)
    _ = key.withUnsafeMutableBytes { keyBytes in
      password.withUnsafeBytes { passwordBytes in
        salt.withUnsafeBytes { saltBytes in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
            saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
            keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
        }
      }
    }
    return key
  }

  /// Decrypts one `v10` value. Database schema 24+ prefixes the plaintext with
  /// SHA-256(host_key), which is dropped.
  static func decrypt(_ encrypted: Data, key: Data, schemaVersion: Int) -> String? {
    let prefix = Data("v10".utf8)
    guard encrypted.starts(with: prefix) else { return nil }
    let ciphertext = encrypted.dropFirst(prefix.count)
    guard let plaintext = aes128CBC(Data(ciphertext), key: key, operation: CCOperation(kCCDecrypt))
    else { return nil }
    let value =
      schemaVersion >= 24 && plaintext.count >= 32 ? plaintext.dropFirst(32) : plaintext[...]
    return String(data: Data(value), encoding: .utf8)
  }

  static func aes128CBC(_ input: Data, key: Data, operation: CCOperation) -> Data? {
    let initVector = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    var output = Data(count: input.count + kCCBlockSizeAES128)
    var moved = 0
    let outputCount = output.count
    let status = output.withUnsafeMutableBytes { outBytes in
      input.withUnsafeBytes { inBytes in
        key.withUnsafeBytes { keyBytes in
          initVector.withUnsafeBytes { ivBytes in
            CCCrypt(
              operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
              keyBytes.baseAddress, key.count, ivBytes.baseAddress,
              inBytes.baseAddress, input.count, outBytes.baseAddress, outputCount, &moved)
          }
        }
      }
    }
    guard status == kCCSuccess else { return nil }
    return output.prefix(moved)
  }

  struct Row: Equatable {
    var hostKey: String
    var name: String
    var value: String
    var path: String
    var expiresUTC: Int64
    var hasExpires: Bool
    var isSecure: Bool
    var isHTTPOnly: Bool
    /// -1 unspecified, 0 none, 1 lax, 2 strict.
    var sameSite: Int
  }

  static func cookie(from row: Row, now: Date = .now) -> HTTPCookie? {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .domain: row.hostKey,
      .path: row.path.isEmpty ? "/" : row.path,
      .name: row.name,
      .value: row.value,
    ]
    if row.hasExpires, let expires = date(fromChromeTime: row.expiresUTC) {
      guard expires > now else { return nil }
      properties[.expires] = expires
    }
    if row.isSecure { properties[.secure] = "TRUE" }
    if row.isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
    switch row.sameSite {
    case 1: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
    case 2: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
    default: break
    }
    return HTTPCookie(properties: properties)
  }

  /// Reads the Keychain item once per launch. The first read raises the macOS
  /// "supacode wants to use Chrome Safe Storage" prompt.
  private static let keyCache = KeyCache()

  static func storageKey() throws -> Data {
    if let key = keyCache.key { return key }
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "Chrome Safe Storage",
      kSecAttrAccount: "Chrome",
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let password = result as? Data else {
      throw Failure.keychainDenied(status)
    }
    let key = deriveKey(password: password)
    keyCache.key = key
    return key
  }

  /// Every unexpired cookie Chrome holds for `hosts` in `profile`. The live
  /// database is locked by Chrome, so it is copied (with its WAL) first.
  static func cookies(forHosts hosts: Set<String>, profile: String) throws -> [HTTPCookie] {
    let source = supportDirectory.appending(path: profile).appending(path: "Cookies")
    guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
      throw Failure.cookieFileMissing
    }
    let key = try storageKey()
    let scratch = URL.temporaryDirectory.appending(path: "supacode-chrome-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let copy = scratch.appending(path: "Cookies")
    try FileManager.default.copyItem(at: source, to: copy)
    for suffix in ["-wal", "-shm"] {
      let sidecar = URL(filePath: source.path(percentEncoded: false) + suffix)
      if FileManager.default.fileExists(atPath: sidecar.path(percentEncoded: false)) {
        try? FileManager.default.copyItem(
          at: sidecar, to: URL(filePath: copy.path(percentEncoded: false) + suffix))
      }
    }
    return try readRows(at: copy, hosts: hosts, key: key).compactMap { cookie(from: $0) }
  }

  private static func readRows(at url: URL, hosts: Set<String>, key: Data) throws -> [Row] {
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(url.path(percentEncoded: false), &database, SQLITE_OPEN_READWRITE, nil)
        == SQLITE_OK
    else {
      defer { sqlite3_close(database) }
      throw Failure.database(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_close(database) }
    let schemaVersion =
      Int(scalar(database, "SELECT value FROM meta WHERE key = 'version'") ?? "0") ?? 0
    let placeholders = Array(repeating: "?", count: hosts.count).joined(separator: ",")
    let sql = """
      SELECT host_key, name, value, encrypted_value, path, expires_utc, has_expires,
        is_secure, is_httponly, samesite
      FROM cookies WHERE host_key IN (\(placeholders))
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw Failure.database(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (index, host) in hosts.sorted().enumerated() {
      sqlite3_bind_text(statement, Int32(index + 1), host, -1, transient)
    }
    var rows: [Row] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let hostKey = text(statement, 0)
      var value = text(statement, 2)
      if let blob = sqlite3_column_blob(statement, 3) {
        let encrypted = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 3)))
        if !encrypted.isEmpty {
          guard let decrypted = decrypt(encrypted, key: key, schemaVersion: schemaVersion) else {
            continue
          }
          value = decrypted
        }
      }
      rows.append(
        Row(
          hostKey: hostKey, name: text(statement, 1), value: value, path: text(statement, 4),
          expiresUTC: sqlite3_column_int64(statement, 5),
          hasExpires: sqlite3_column_int(statement, 6) != 0,
          isSecure: sqlite3_column_int(statement, 7) != 0,
          isHTTPOnly: sqlite3_column_int(statement, 8) != 0,
          sameSite: Int(sqlite3_column_int(statement, 9))))
    }
    return rows
  }

  private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
    guard let pointer = sqlite3_column_text(statement, column) else { return "" }
    return String(cString: pointer)
  }

  private static func scalar(_ database: OpaquePointer?, _ sql: String) -> String? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return text(statement, 0)
  }

  private final class KeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var key: Data? {
      get { lock.withLock { stored } }
      set { lock.withLock { stored = newValue } }
    }
  }
}

/// Opens and watches the small app-mode Chrome window a pane signs in through.
/// Window lookups go through Chrome's AppleScript dictionary (the first one
/// raises the macOS Automation prompt); without it the popup still works and
/// the pane picks the sign-in up when Supacode comes back to the front.
@MainActor
enum ChromePopup {
  static let bundleIdentifier = "com.google.Chrome"

  static var isInstalled: Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
  }

  /// Opens `url` as a Chrome app window and returns its AppleScript window id
  /// when it can be identified.
  static func open(_ url: URL, profile: String) async -> Int? {
    guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    else { return nil }
    let before = Set(windowIDs() ?? [])
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = true
    configuration.arguments = [
      "--profile-directory=\(profile)", "--app=\(url.absoluteString)", "--window-size=520,760",
    ]
    _ = try? await NSWorkspace.shared.openApplication(at: chrome, configuration: configuration)
    for _ in 0..<20 {
      try? await Task.sleep(for: .milliseconds(250))
      if let ids = windowIDs(), let new = ids.first(where: { !before.contains($0) }) {
        return new
      }
    }
    return nil
  }

  /// The popup's current URL, or nil once the window is gone.
  static func currentURL(ofWindow id: Int) -> URL?? {
    guard
      let result = run(
        """
        tell application id "\(bundleIdentifier)"
          if not (exists window id \(id)) then return "__closed__"
          return URL of active tab of window id \(id)
        end tell
        """)
    else { return .none }
    if result == "__closed__" { return .some(nil) }
    return .some(URL(string: result))
  }

  static func close(window id: Int) {
    _ = run(
      """
      tell application id "\(bundleIdentifier)"
        if exists window id \(id) then close window id \(id)
      end tell
      """)
  }

  private static func windowIDs() -> [Int]? {
    guard
      let result = run(
        """
        tell application id "\(bundleIdentifier)"
          set AppleScript's text item delimiters to ","
          return (id of every window) as text
        end tell
        """)
    else { return nil }
    return result.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
  }

  private static func run(_ source: String) -> String? {
    guard
      NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
        == false
    else { return nil }
    var error: NSDictionary?
    guard let output = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil
    else {
      return nil
    }
    return output.stringValue
  }
}
