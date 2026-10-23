#!/usr/bin/env bash
# claude-simulator.sh — give each Claude Code session its own iOS simulator
#
# Several Claude sessions run at once, sometimes more than one in a
# worktree, and a simulator shared between them gets shut down or taken over
# mid-run by another session's build or test. So every session in an iOS
# project gets its own:
#
#   Claude sim <worktree> <pid>   an iPhone 17 Pro on the newest iOS
#
# and its own DerivedData, since concurrent builds sharing one lock and
# overwrite each other. Set CLAUDE_SIMULATOR_DEVICE_TYPE (a simctl device
# type identifier) in a project's settings env to use another device.
#
# Its owner is the Claude Code process running the session: the first
# ancestor that isn't a shell, found from the hook that starts the session
# or from any command the session runs, so both find the same simulator. A
# /clear keeps the process, and with it the simulator. The owner's pid and
# start time are kept in a registry file per simulator, in
# ~/Library/Caches/claude-ios-simulator, shared by every project.
#
# Simulators are swept, so they don't pile up: when their owner process has
# exited (or the pid now belongs to another process), when their worktree is
# gone, or when they have no registry file and are over ten minutes old.
# Every session start sweeps in the background, every session end sweeps
# once its process has exited, and a delete-worktree script can sweep the
# worktree it deletes. Only simulators named "Claude sim ..." are ever
# touched.
#
# Usage: claude-simulator.sh <command>
#   udid                     this session's simulator UDID, made if missing
#   derived-data-path        this session's DerivedData directory
#   session-start            SessionStart hook
#   session-end              SessionEnd hook
#   sweep [--worktree PATH]  delete simulators whose owner is gone, and
#                            every one belonging to PATH

set -euo pipefail

NAME_PREFIX="Claude sim "
DEVICE_TYPE="${CLAUDE_SIMULATOR_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
REGISTRY="$HOME/Library/Caches/claude-ios-simulator"
DEVICES="$HOME/Library/Developer/CoreSimulator/Devices"
DERIVED_DATA_ROOT="$HOME/Library/Developer/Xcode/DerivedData/claude-sim"
LOCK="$REGISTRY/.lock"
# A simulator without a registry file this old was never finished being made.
ORPHAN_AGE_SECONDS=600

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# The Claude Code process this command runs under: the first ancestor that
# isn't a shell. Prints nothing outside Claude Code.
owner_pid() {
  local process="$$" command
  while process="$(ps -o ppid= -p "$process" 2>/dev/null | tr -d ' ')"; [[ -n "$process" && "$process" != 1 ]]; do
    command="$(ps -o comm= -p "$process" 2>/dev/null)"
    command="$(basename "${command#-}")"
    case "$command" in
      sh | bash | zsh | dash) ;;
      *) echo "$process"; return ;;
    esac
  done
}

# When process $1 started, which with its pid says it's still the same one.
started_at() {
  ps -o lstart= -p "$1" 2>/dev/null | sed 's/ *$//'
}

worktree_root() {
  git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null || echo "${1:-$PWD}"
}

# Whether the current directory's project has an Xcode project or workspace
# near its root. Sessions anywhere else get no simulator.
is_ios_project() {
  [[ -n "$(find "$(worktree_root)" -maxdepth 3 \
    \( -name node_modules -o -name .build -o -name DerivedData -o -name .git \) -prune -o \
    \( -name '*.xcodeproj' -o -name '*.xcworkspace' \) -print -quit 2>/dev/null)" ]]
}

derived_data_path() {
  echo "$DERIVED_DATA_ROOT/$1"
}

# One sweep or creation at a time. A lock older than two minutes was left by
# a run that died, and is taken over.
take_lock() {
  mkdir -p "$REGISTRY"
  local attempts=0
  until mkdir "$LOCK" 2>/dev/null; do
    if [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]]; then
      rm -rf "$LOCK"
      continue
    fi
    attempts=$((attempts + 1))
    if ((attempts > 600)); then
      echo "error: $LOCK is held; remove it if no other run is going" >&2
      exit 1
    fi
    sleep 0.1
  done
  trap 'rm -rf "$LOCK"' EXIT
}

release_lock() {
  rm -rf "$LOCK"
  trap - EXIT
}

# The "Claude sim ..." simulators, one "udid<TAB>name" per line.
session_simulators() {
  xcrun simctl list devices -j | jq -r --arg prefix "$NAME_PREFIX" '
    .devices[][] | select(.name | startswith($prefix)) | "\(.udid)\t\(.name)"'
}

simulator_exists() {
  xcrun simctl list devices -j | jq -e --arg udid "$1" '[.devices[][] | select(.udid == $udid)] | length > 0' >/dev/null
}

newest_ios_runtime() {
  xcrun simctl list runtimes available -j | jq -r '
    [.runtimes[] | select(.platform == "iOS")]
    | sort_by(.version | split(".") | map(tonumber)) | last | .identifier'
}

# The UDID on record for owner $1 started at $2, if any.
registered_simulator() {
  local owner="$1" started="$2" file
  for file in "$REGISTRY"/*; do
    [[ -f "$file" ]] || continue
    if [[ "$(sed -n 's/^OWNER_PID=//p' "$file")" == "$owner" && "$(sed -n 's/^OWNER_STARTED=//p' "$file")" == "$started" ]]; then
      basename "$file"
      return
    fi
  done
}

# This session's simulator UDID, making it and its registry file if needed.
simulator_for_owner() {
  local owner="$1" session_id="${2:-}" started worktree udid name
  started="$(started_at "$owner")"
  worktree="$(worktree_root)"

  take_lock
  udid="$(registered_simulator "$owner" "$started")"
  if [[ -n "$udid" ]]; then
    if simulator_exists "$udid"; then
      release_lock
      echo "$udid"
      return
    fi
    rm -f "$REGISTRY/$udid"
  fi

  name="$NAME_PREFIX$(basename "$worktree") $owner"
  udid="$(xcrun simctl create "$name" "$DEVICE_TYPE" "$(newest_ios_runtime)")"
  {
    echo "OWNER_PID=$owner"
    echo "OWNER_STARTED=$started"
    echo "WORKTREE=$worktree"
    echo "SESSION_ID=$session_id"
  } >"$REGISTRY/$udid"
  release_lock
  echo "$udid"
}

simulator_name() {
  xcrun simctl list devices -j | jq -r --arg udid "$1" '.devices[][] | select(.udid == $udid) | .name'
}

delete_simulator() {
  local udid="$1" name="$2" reason="$3"
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  rm -f "$REGISTRY/$udid"
  rm -rf "$(derived_data_path "$udid")"
  echo "✓ Deleted simulator \"$name\" ($reason)"
}

sweep() {
  local deleted_worktree="" udid name file owner started worktree age
  if [[ "${1:-}" == "--worktree" ]]; then
    deleted_worktree="$(cd "${2:?--worktree needs a path}" 2>/dev/null && pwd -P || echo "$2")"
  fi

  take_lock
  while IFS=$'\t' read -r udid name; do
    [[ -n "$udid" ]] || continue
    file="$REGISTRY/$udid"
    if [[ ! -f "$file" ]]; then
      age=$(($(date +%s) - $(stat -f %m "$DEVICES/$udid" 2>/dev/null || date +%s)))
      if ((age > ORPHAN_AGE_SECONDS)); then
        delete_simulator "$udid" "$name" "no owner on record"
      fi
      continue
    fi
    owner="$(sed -n 's/^OWNER_PID=//p' "$file")"
    started="$(sed -n 's/^OWNER_STARTED=//p' "$file")"
    worktree="$(sed -n 's/^WORKTREE=//p' "$file")"
    if [[ -n "$deleted_worktree" && "$(cd "$worktree" 2>/dev/null && pwd -P || echo "$worktree")" == "$deleted_worktree" ]]; then
      delete_simulator "$udid" "$name" "its worktree is being deleted"
    elif [[ ! -d "$worktree" ]]; then
      delete_simulator "$udid" "$name" "its worktree is gone"
    elif [[ -z "$owner" || "$(started_at "$owner")" != "$started" ]]; then
      delete_simulator "$udid" "$name" "its session has ended"
    fi
  done < <(session_simulators)

  # Registry files and DerivedData whose simulator was deleted some other way.
  for file in "$REGISTRY"/* "$DERIVED_DATA_ROOT"/*; do
    [[ -e "$file" ]] || continue
    if ! simulator_exists "$(basename "$file")"; then
      rm -rf "$file"
    fi
  done
  release_lock
}

# Runs `sweep` in the background, outliving the hook that started it.
sweep_in_background() {
  nohup "$SCRIPT_PATH" sweep >/dev/null 2>&1 &
}

require_owner() {
  local owner
  owner="$(owner_pid)"
  if [[ -z "$owner" ]]; then
    echo "error: not running under a Claude Code session" >&2
    exit 1
  fi
  echo "$owner"
}

# What the session is told at its start, and again after /clear or a
# compaction: the simulator to use and the rules for using it.
session_context() {
  local udid="$1" name="$2"
  cat <<EOF
iOS simulator for this session: "$name" ($udid), with its own DerivedData. Every shell command has \$CLAUDE_SIMULATOR_UDID and \$CLAUDE_DERIVED_DATA_PATH; "$SCRIPT_PATH" udid prints the UDID again.
- Use this simulator and no other: never the author's booted simulator, another session's, or one picked by name. Destinations are -destination "platform=iOS Simulator,id=\$CLAUDE_SIMULATOR_UDID" with -derivedDataPath "\$CLAUDE_DERIVED_DATA_PATH", or 'generic/platform=iOS Simulator' for a build that runs nothing.
- Never use the author's Xcode window or workspace session (the Xcode MCP BuildProject, RunProject or workspace device sessions); for taps, start a non-workspace device session on this UDID.
- Never run open -a Simulator, computer use, AppleScript or synthetic clicks on the simulator, "booted" as a simctl device, or simctl commands on all devices.
- Only use the simulator to debug something non-trivial; otherwise list steps for the author to check by hand.
The ios-simulator skill has the details.
EOF
}

case "${1:-}" in
  udid)
    owner="$(require_owner)"
    simulator_for_owner "$owner"
    ;;

  derived-data-path)
    owner="$(require_owner)"
    derived_data_path "$(simulator_for_owner "$owner")"
    ;;

  session-start)
    input="$(cat)"
    session_id="$(jq -r '.session_id // empty' <<<"$input")"
    cwd="$(jq -r '.cwd // empty' <<<"$input")"
    if [[ -n "$cwd" ]]; then
      cd "$cwd"
    fi
    is_ios_project || exit 0
    # A project still running its own copy of this scheme keeps it.
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -e "$CLAUDE_PROJECT_DIR/scripts/claude-simulator.sh" ]]; then
      exit 0
    fi
    owner="$(require_owner)"
    udid="$(simulator_for_owner "$owner" "$session_id")"
    name="$(simulator_name "$udid")"
    if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
      {
        echo "export CLAUDE_SIMULATOR_UDID=$udid"
        echo "export CLAUDE_SIMULATOR_NAME='$name'"
        echo "export CLAUDE_DERIVED_DATA_PATH='$(derived_data_path "$udid")'"
      } >>"$CLAUDE_ENV_FILE"
    fi
    sweep_in_background
    session_context "$udid" "$name"
    ;;

  session-end)
    input="$(cat)"
    # A /clear starts a new session in the same process, which keeps its
    # simulator.
    if [[ "$(jq -r '.reason // empty' <<<"$input")" == "clear" ]]; then
      exit 0
    fi
    owner="$(owner_pid)"
    # Sessions that never made a simulator have nothing to sweep.
    if [[ -z "$owner" || -z "$(registered_simulator "$owner" "$(started_at "$owner")")" ]]; then
      exit 0
    fi
    # The hook has 1.5 seconds; the sweep waits for the process to exit.
    # shellcheck disable=SC2016 # expanded by the inner bash, from its arguments
    nohup bash -c '
      for _ in $(seq 60); do kill -0 "$1" 2>/dev/null || break; sleep 1; done
      "$2" sweep
    ' _ "$owner" "$SCRIPT_PATH" >/dev/null 2>&1 &
    ;;

  sweep)
    shift
    sweep "$@"
    ;;

  *)
    echo "Usage: $0 udid | derived-data-path | session-start | session-end | sweep [--worktree PATH]" >&2
    exit 1
    ;;
esac
