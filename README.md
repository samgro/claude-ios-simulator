# ios-simulator

A Claude Code plugin that gives every Claude session in an iOS project its
own simulator and DerivedData, and keeps sessions off everyone else's.

Run a few Claude sessions at once, across worktrees or in one, and they start
killing each other's work: one session's `xcodebuild test` shuts down the
simulator another is testing on ("Test crashed with signal term"), builds
that share DerivedData lock and overwrite each other, and sooner or later a
session runs its UI tests on the simulator you're signed in on.

## What it does

- **SessionStart:** in a repo with an `.xcodeproj` or `.xcworkspace` within
  three levels of its root, makes or reuses this session's simulator,
  `Claude sim <worktree> <pid>` (an iPhone 17 Pro on the newest installed
  iOS, created but not booted). Exports `CLAUDE_SIMULATOR_UDID`,
  `CLAUDE_SIMULATOR_NAME` and `CLAUDE_DERIVED_DATA_PATH` to every shell
  command, and tells Claude the simulator and the rules for using it. In any
  other repo it does nothing.
- **SessionEnd:** once the Claude Code process has exited, sweeps.
- **Sweep:** deletes a `Claude sim …` simulator (and its DerivedData) whose
  session process has exited, whose worktree is gone, or that was left half
  made. Nothing else is ever touched.
- **Guard (PreToolUse on Bash):** refuses `open -a Simulator`, `booted` as a
  simctl device, simctl on all devices, killing Simulator processes, and
  `xcodebuild -destination '…name=…'`, with a reason pointing at the
  session's own simulator.
- **Skill `ios-simulator`:** how to build, test, run, screenshot and tap on
  the session's simulator.

A simulator belongs to the Claude Code process, not the session id or the
worktree: `/clear` keeps it, two sessions in one worktree get two, and a
command run by the session (or a subagent) finds the same one by walking up
to that process. Its pid and start time are recorded in
`~/Library/Caches/claude-ios-simulator`, so a reused pid doesn't keep a
simulator alive.

## Install

For yourself, in every project:

```
/plugin marketplace add samgro/claude-ios-simulator
/plugin install ios-simulator@samgro
```

For everyone working on a repo, add it to the repo's `.claude/settings.json`;
Claude Code offers to install it when someone trusts the folder:

```json
{
  "extraKnownMarketplaces": {
    "samgro": {
      "source": { "source": "github", "repo": "samgro/claude-ios-simulator" }
    }
  },
  "enabledPlugins": { "ios-simulator@samgro": true }
}
```

Requires macOS with Xcode, and `jq`.

### Options

Set these in a project's `.claude/settings.json` `env`:

- `CLAUDE_SIMULATOR_DEVICE_TYPE`: a simctl device type identifier
  (`xcrun simctl list devicetypes`), for example
  `com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB`.

### Worktree scripts

If your repo has scripts that create and delete worktrees, the
`ios-simulator` skill has two snippets: copying Xcode's run-destination state
into a new worktree, and sweeping a deleted worktree's simulators.

## Commands

```
scripts/claude-simulator.sh udid                     # this session's UDID
scripts/claude-simulator.sh derived-data-path        # its DerivedData
scripts/claude-simulator.sh sweep [--worktree PATH]  # clean up by hand
```

## Related

- Claude Code Desktop's [iOS simulator pane](https://code.claude.com/docs/en/desktop-ios-simulator)
  also ties simulators to sessions, for the simulators it boots in the
  Desktop app. This plugin covers CLI sessions, `xcodebuild` and UI tests.
- [ai-aligned-xcode](https://github.com/ai-ecoverse/ai-aligned-xcode)
  shadows `xcodebuild` and `xcrun` on `PATH` and isolates per worktree;
  [xwt](https://github.com/taki-on/xwt) pairs worktrees with simulators;
  [SimLease](https://github.com/RoshanDewmina/simlease) leases simulators
  from a daemon. This plugin is per session, needs no daemon or `PATH`
  changes, and never renames or claims a simulator it didn't make.

## License

MIT
