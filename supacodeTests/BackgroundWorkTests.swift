import ComposableArchitecture
import Darwin
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct BackgroundWorkTests {
  typealias Feature = AgentPresenceFeature

  // MARK: - Wrapper parsing.

  @Test func extractsTheEvalBodyFromAClaudeCodeWrapper() {
    let wrapper =
      "/bin/zsh -c source /Users/me/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true"
      + " && eval 'railway ssh -- python -m src.main --issue 2790' < /dev/null && pwd -P >| /tmp/cwd"
    #expect(
      BackgroundWorkProbe.displayCommand(fromWrapper: wrapper) == "railway ssh -- python -m src.main --issue 2790")
  }

  @Test(arguments: [
    #"zsh -c x && eval 'echo '"'"'hi'"'"' && sleep 5' < /dev/null && pwd -P"#,
    #"zsh -c x && eval 'echo '\''hi'\'' && sleep 5' < /dev/null && pwd -P"#,
  ])
  func undoesSingleQuoteEscapes(_ wrapper: String) {
    #expect(BackgroundWorkProbe.displayCommand(fromWrapper: wrapper) == "echo 'hi' && sleep 5")
  }

  @Test func unfamiliarShapeFallsBackToTheRawArgv() {
    let raw = "/bin/zsh -c source /Users/me/.claude/shell-snapshots/x.sh && make test"
    #expect(BackgroundWorkProbe.displayCommand(fromWrapper: raw) == raw)
  }

  // MARK: - Reducer.

  @Test func resultFillsTheRowSnapshotOnlyWhileIdle() {
    var state = Feature.State()
    let reducer = Feature()
    let surfaceID = UUID()
    _ = reducer.reduce(
      into: &state,
      action: .programStatusReceived(
        surfaceID: surfaceID, report: ProgramStatusReport(state: .idle, app: "claude-code")))
    _ = reducer.reduce(into: &state, action: .backgroundWorkResult([surfaceID: ["sleep 300"]]))

    #expect(state.rowSnapshot(across: [surfaceID], badgesEnabled: true).backgroundCommands == ["sleep 300"])

    _ = reducer.reduce(
      into: &state,
      action: .programStatusReceived(
        surfaceID: surfaceID, report: ProgramStatusReport(state: .working, app: "claude-code")))
    #expect(state.rowSnapshot(across: [surfaceID], badgesEnabled: true).backgroundCommands.isEmpty)
  }

  @Test func emptyResultClearsAndClosingASurfaceDropsIt() {
    var state = Feature.State()
    let reducer = Feature()
    let first = UUID()
    let second = UUID()
    _ = reducer.reduce(into: &state, action: .backgroundWorkResult([first: ["a"], second: ["b"]]))
    _ = reducer.reduce(into: &state, action: .surfaceClosed(first))
    #expect(state.backgroundWork == [second: ["b"]])
    _ = reducer.reduce(into: &state, action: .backgroundWorkResult([:]))
    #expect(state.backgroundWork.isEmpty)
  }
}
