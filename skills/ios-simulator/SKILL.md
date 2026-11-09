---
name: ios-simulator
description: How to build, test, run and inspect an iOS app on this Claude session's own simulator without touching the author's or another session's. Load before any xcodebuild test/run, simctl command, UI test, screenshot or simulator tap, and when writing worktree setup or teardown scripts for an iOS repo.
---

# This session's iOS simulator

Every Claude Code session in an iOS project gets its own simulator when it
starts, named `Claude sim <worktree> <pid>`, and its own DerivedData. Other
sessions run at the same time, sometimes in the same worktree, and the
author has their own simulators with their sign-in and state on them. A
simulator or DerivedData directory shared with any of them gets shut down,
reinstalled or overwritten mid-run.

| What | Where |
|---|---|
| Simulator UDID | `$CLAUDE_SIMULATOR_UDID` |
| Simulator name | `$CLAUDE_SIMULATOR_NAME` |
| DerivedData | `$CLAUDE_DERIVED_DATA_PATH` |

If a variable is missing (a shell started before the hook, or the simulator
was swept), the session-start note names the script. `claude-simulator.sh
udid` and `claude-simulator.sh derived-data-path` print both, making the
simulator again if needed. Its device is created but not booted; the first
test or `simctl boot` boots it.

## Building

A build that runs nothing needs no simulator at all:

```
xcodebuild -scheme <Scheme> -destination 'generic/platform=iOS Simulator' build
```

## Testing and running

Always by UDID, into this session's DerivedData:

```
xcodebuild -scheme <Scheme> \
  -destination "platform=iOS Simulator,id=$CLAUDE_SIMULATOR_UDID" \
  -derivedDataPath "$CLAUDE_DERIVED_DATA_PATH" test
```

To run the app, build it the same way with `build`, then:

```
xcrun simctl boot "$CLAUDE_SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl install "$CLAUDE_SIMULATOR_UDID" \
  "$CLAUDE_DERIVED_DATA_PATH"/Build/Products/Debug-iphonesimulator/<App>.app
xcrun simctl launch "$CLAUDE_SIMULATOR_UDID" <bundle id> [launch arguments]
xcrun simctl io "$CLAUDE_SIMULATOR_UDID" screenshot <scratchpad>/screen.png
```

Never pass `booted` as the device: it means whichever simulator is booted,
often the author's.

## Looking and tapping

- Screenshots with `simctl io … screenshot`, then read the image.
- Find elements by the accessibility tree, not pixels. Add
  `accessibilityIdentifier`s in code when automation needs them.
- For taps and swipes, start a non-workspace device session with the Xcode
  MCP `DeviceInteractionStartSession` on `$CLAUDE_SIMULATOR_UDID`, and end it
  when done. Never the workspace variants, `BuildProject` or `RunProject`:
  they drive the author's open Xcode window and its run destination.
- Never `open -a Simulator`, computer use, AppleScript or synthetic clicks.
- For a walkthrough that has to be repeatable, write a UI test and run it
  with the test command above.

A guard hook refuses `open -a Simulator`, `booted`, simctl on all devices,
killing Simulator processes, and xcodebuild destinations picked by name.

## When to use the simulator at all

Only to debug something non-trivial or to reproduce a bug. For a change
you're confident in, list the steps for the author to check by hand
instead.

## Xcode previews

To see how one SwiftUI view looks, render its `#Preview` with the Xcode MCP
`RenderPreview` instead of building, installing and launching the app. It is
one tool call, returns a snapshot, needs no launch arguments to reach the
screen, and runs in Xcode's preview processes rather than on any simulator.

Use a preview for layout, styling, copy, dark mode, Dynamic Type,
localization, and each state of a view (empty, loading, error, long text).
Use the simulator or a test for navigation, gestures, the keyboard, scrolling,
real data, persistence, networking or app lifecycle.

- Pass this checkout's `.xcodeproj` or `.xcworkspace` by absolute path as
  `workspaceIdentifier`. Otherwise it renders the workspace the author has
  open, which in a worktree is a different checkout.
- `sourceFilePath` is the file's path in the project; pick which `#Preview`
  in the file with `previewDefinitionIndexInFile` (zero-based).
- The first render lists `supportedPreviewVariantOverrides`,
  `supportedLocalizations` and `supportedCanvasControlOverrides`. Use those on
  later calls for dark mode, text sizes, locales, `arguments:` items and
  widget timelines, rather than editing the preview code.
- If the view has no preview for the state you need, add a named one
  (`#Preview("Error state")`) built from in-memory fixtures: no network, no
  real store, no app-level setup. Previews like that render quickly and the
  same way every time, and the author keeps them.
- The first render compiles; later renders after small edits are much faster.
  Re-render after each change rather than batching edits blind.
- If a render fails, read the error once. It is usually a missing environment
  value or model container in the preview. If the second attempt fails too,
  fall back to the simulator or to manual steps.

## Fast verification

Once you do use the simulator, be quick. A check the author could do by hand in
seconds should not take minutes.

- If the check is how a single view looks, render a preview instead (see
  above).

- Budget about five tool calls for a UI check. If it isn't verified by then,
  stop and give the author manual steps instead.
- Never `clean`. Always build into `$CLAUDE_DERIVED_DATA_PATH` so builds are
  incremental, and skip the build if no source changed since the last one. Use
  `build`, not `test`, when only checking UI. Pass `-quiet` and `tail` the
  output.
- Boot once and leave it booted. Don't shut down or erase it between checks.
- Don't tap through the app to reach the screen you want to see. Launch
  straight into it: add DEBUG-only launch arguments or a deep link for the
  state you need, and pass them with `simctl launch`.
- Take one screenshot per check, right after launch. No polling loops. If an
  animation matters, wait once, then screenshot.
- If you must tap or swipe, start one device session, batch every interaction,
  and end it. Target elements by accessibility identifier, not coordinates.
- For logic bugs, reproduce with a unit test instead of the UI. A test target
  or package that doesn't need a simulator (for example `swift test`) runs in
  seconds.
- Run independent commands in parallel, such as building while the simulator
  boots.

## Subagents

Subagents and workflow agents run in the session's process, so they share
its simulator. Only one of them drives it at a time: run simulator work in
the parent, or in one subagent.

## Worktrees

- When a script makes a new worktree, copy the main checkout's
  `<Project>.xcodeproj/project.xcworkspace/xcuserdata/$USER.xcuserdatad/UserInterfaceState.xcuserstate`
  into it (copy, don't symlink). It holds the author's selected run
  destination; without it Xcode picks a simulator itself, often a Claude
  one.
- When a script deletes a worktree, sweep its simulators:
  `claude-simulator.sh sweep --worktree <path>`. Find the script from the
  installed plugin:
  `jq -r '.plugins["ios-simulator@samgro"][0].installPath' ~/.claude/plugins/installed_plugins.json`.

## Cleanup

Simulators are swept when their session's process exits, when their
worktree is gone, or when they were left half made. Every session start and
end sweeps; `claude-simulator.sh sweep` does it by hand. Only `Claude sim …`
simulators are ever deleted.
