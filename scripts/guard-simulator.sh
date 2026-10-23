#!/usr/bin/env bash
# PreToolUse hook for Bash: refuses commands that reach simulators this
# session doesn't own. The author's own simulator, with their sign-in and
# state on it, and other sessions' simulators are off limits; each session
# has its own (claude-simulator.sh).
set -euo pipefail

command=$(jq -r '.tool_input.command // ""')
simulator_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-simulator.sh"
use_own="Use this session's own simulator: -destination \"platform=iOS Simulator,id=\$CLAUDE_SIMULATOR_UDID\" (\"$simulator_script\" udid prints it), or 'generic/platform=iOS Simulator' for a build that runs nothing."

deny() {
  jq -cn --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

if grep -Eq '(^|[;&|(`[:space:]])open[[:space:]][^;&|]*Simulator(\.app)?(["'"'"'[:space:];&|)]|$)' <<<"$command"; then
  deny "Don't open the Simulator app: it shows and drives the author's simulators. Verify with simctl screenshots and accessibility dumps instead. $use_own"
fi

if grep -Eq 'simctl[[:space:]]+(shutdown|erase|delete)[[:space:]]+(all|unavailable)([^[:alnum:]]|$)' <<<"$command"; then
  deny "simctl on all devices reaches the author's simulators and other sessions'. Name this session's UDID instead. $use_own"
fi

if grep -Eq '(^|[^[:alnum:]_./-])(killall|pkill)[^;&|]*(Simulator|CoreSimulator|launchd_sim)' <<<"$command"; then
  deny "Killing Simulator processes takes down every session's simulator and the author's. Shut down only this session's: xcrun simctl shutdown \"\$CLAUDE_SIMULATOR_UDID\"."
fi

if grep -Eq 'simctl[[:space:]]' <<<"$command" && ! grep -Eq 'simctl[[:space:]]+list' <<<"$command" \
  && grep -Eq '[[:space:]]booted(["'"'"'[:space:];&|)]|$)' <<<"$command"; then
  deny "\"booted\" means whichever simulator is booted, often the author's. $use_own"
fi

if grep -Eq '(^|[^[:alnum:]_])xcodebuild[[:space:]]' <<<"$command" \
  && grep -Eq -- '-destination[[:space:]]+(["'"'"'][^"'"'"']*|([^[:space:]\\]|\\.)*)name=' <<<"$command"; then
  deny "A destination picked by name is shared with the author and other sessions. $use_own"
fi

exit 0
