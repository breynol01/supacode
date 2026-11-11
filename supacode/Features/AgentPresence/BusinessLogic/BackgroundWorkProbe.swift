import Darwin
import Foundation

/// Finds work an idle agent has left running: shell commands the agent spawned
/// that outlive its turn (a background build, a poll, a dispatched LangGraph
/// run). Agent-agnostic by construction; it only inspects the agent's process
/// tree, so any new repo or tool is covered without wiring.
///
/// A child counts only when its argv carries a known agent shell-wrapper
/// marker. That excludes the long-lived helpers every agent also parents (MCP
/// servers, language servers, `caffeinate`), which would otherwise pin the
/// indicator on for the whole session.
nonisolated enum BackgroundWorkProbe {
  /// Argv substrings identifying an agent-spawned shell command. Claude Code
  /// runs every Bash tool call, foreground or background, as
  /// `zsh -c source ~/.claude/shell-snapshots/<snapshot> … eval '<cmd>' …`.
  static let shellWrapperMarkers = ["/.claude/shell-snapshots/"]

  /// Display commands for every marked child of the given agent pids.
  static func commands(forAgentPids pids: Set<pid_t>) -> [String] {
    pids.sorted().flatMap { pid in
      childPids(of: pid).compactMap { child in
        guard let argv = arguments(of: child) else { return nil }
        let joined = argv.joined(separator: " ")
        guard shellWrapperMarkers.contains(where: joined.contains) else { return nil }
        return displayCommand(fromWrapper: joined)
      }
    }
  }

  /// The user-facing command inside a Claude Code wrapper: the body of
  /// `eval '<cmd>'`, with the single-quote escapes (`'"'"'` or `'\''`) undone.
  /// Falls back to the raw argv when the shape is unfamiliar.
  static func displayCommand(fromWrapper wrapper: String) -> String {
    guard let start = wrapper.range(of: "eval '") else { return wrapper }
    let body = wrapper[start.upperBound...]
    let end = body.range(of: "' < /dev/null") ?? body.range(of: "'", options: .backwards)
    guard let end else { return wrapper }
    return String(body[..<end.lowerBound])
      .replacingOccurrences(of: #"'"'"'"#, with: "'")
      .replacingOccurrences(of: #"'\''"#, with: "'")
  }

  private static func childPids(of pid: pid_t) -> [pid_t] {
    let capacity = 256
    var buffer = [pid_t](repeating: 0, count: capacity)
    let bytes = buffer.withUnsafeMutableBytes { raw in
      proc_listchildpids(pid, raw.baseAddress, Int32(raw.count))
    }
    guard bytes > 0 else { return [] }
    let count = min(Int(bytes) / MemoryLayout<pid_t>.stride, capacity)
    return buffer.prefix(count).filter { $0 > 0 }
  }

  /// argv via `KERN_PROCARGS2`: argc, the exec path, padding, then argv.
  private static func arguments(of pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }
    var args: [String] = []
    while args.count < argc, index < size {
      let start = index
      while index < size, buffer[index] != 0 { index += 1 }
      args.append(String(decoding: buffer[start..<index], as: UTF8.self))
      index += 1
    }
    return args
  }
}
