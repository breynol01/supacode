import Darwin
import Foundation
import SupacodeSettingsShared

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

  /// Process names of agents whose shell wrapper is recognized above.
  static let agentProcessNames: Set<String> = ["claude"]

  /// Display commands per surface, skipping surfaces whose agent is busy.
  /// Agents are found by the surface id Supacode exports into each terminal's
  /// environment: program-status presence (OSC 7501) carries no pid, and Claude
  /// Code clears its record when a turn ends, so an idle agent has no record
  /// to look up. Hook-reported pids join as extra roots.
  static func commands(
    excludingSurfaces busySurfaces: Set<UUID>,
    knownAgentPids: [UUID: Set<pid_t>] = [:]
  ) -> [UUID: [String]] {
    var roots = knownAgentPids.filter { !busySurfaces.contains($0.key) }
    for (surface, pid) in agentProcesses() where !busySurfaces.contains(surface) {
      roots[surface, default: []].insert(pid)
    }
    return roots.compactMapValues { pids in
      let commands = commands(forAgentPids: pids)
      return commands.isEmpty ? nil : commands
    }
  }

  /// Every running agent process tagged with the surface it was launched in.
  static func agentProcesses() -> [(surface: UUID, pid: pid_t)] {
    let prefix = AgentPresenceOSC.surfaceEnvVar + "="
    return allPids().compactMap { pid in
      guard agentProcessNames.contains(name(of: pid)),
        let entry = processArguments(of: pid)?.environment.first(where: { $0.hasPrefix(prefix) }),
        let surface = UUID(uuidString: String(entry.dropFirst(prefix.count)))
      else { return nil }
      return (surface, pid)
    }
  }

  /// Display commands for every marked child of the given agent pids.
  static func commands(forAgentPids pids: Set<pid_t>) -> [String] {
    pids.sorted().flatMap { pid in
      childPids(of: pid).compactMap { child in
        guard let argv = processArguments(of: child)?.argv else { return nil }
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

  private static func allPids() -> [pid_t] {
    let capacity = 8192
    var buffer = [pid_t](repeating: 0, count: capacity)
    let count = buffer.withUnsafeMutableBytes { raw in
      proc_listallpids(raw.baseAddress, Int32(raw.count))
    }
    guard count > 0 else { return [] }
    return buffer.prefix(min(Int(count), capacity)).filter { $0 > 0 }
  }

  private static func name(of pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
    return String(cString: buffer)
  }

  /// argv and environment via `KERN_PROCARGS2`: argc, the exec path,
  /// padding, argv, then the environment strings.
  private static func processArguments(of pid: pid_t) -> (argv: [String], environment: [String])? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }
    var strings: [String] = []
    while index < size {
      let start = index
      while index < size, buffer[index] != 0 { index += 1 }
      if index == start { break }
      strings.append(String(bytes: buffer[start..<index], encoding: .utf8) ?? "")
      index += 1
    }
    let argCount = min(Int(argc), strings.count)
    return (Array(strings.prefix(argCount)), Array(strings.dropFirst(argCount)))
  }
}
