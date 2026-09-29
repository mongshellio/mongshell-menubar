#!/usr/bin/env bash
# Runs the regression tests: Claude Code settings, the openclaw server agent,
# then the app's openclaw status client.
#
# Not `swift test`: that needs XCTest or swift-testing, and neither ships with
# the Command Line Tools this project builds against (no Xcode required is a
# stated goal — see README § 설치). So the tests are compiled directly against
# the real source files instead, which keeps them honest — they exercise the
# shipping code, not a copy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "▶ compiling settings tests"
swiftc -o "$OUT/tests" \
  "$ROOT/Sources/mongshell-menubar/Services/ClaudeSettingsStore.swift" \
  "$ROOT/Sources/mongshell-menubar/Models/ClaudeSettingsModel.swift" \
  "$ROOT/Tests/ClaudeSettingsTests/main.swift"

echo "▶ running settings tests"
# MONGSHELL_CLAUDE_SETTINGS is set per-case inside the tests; unset it here so a
# value inherited from the shell can never point them at the real settings file.
env -u MONGSHELL_CLAUDE_SETTINGS "$OUT/tests"

# The agent's main.swift is its entry point, so it's left out — the test file
# supplies the top-level code instead.
AGENT="$ROOT/Sources/mongshell-openclaw-agent"
echo "▶ compiling openclaw agent tests"
swiftc -o "$OUT/agent-tests" \
  "$AGENT/Probe.swift" \
  "$AGENT/Heal.swift" \
  "$AGENT/StatusFile.swift" \
  "$ROOT/Tests/OpenClawAgentTests/main.swift"

echo "▶ running openclaw agent tests"
"$OUT/agent-tests"

# The app client is compiled together with the agent's encoder so the
# round-trip case catches any key-name drift between the two targets. The
# @MainActor model (polling, notifications) is left out — its rules live in
# the pure types listed here.
APP="$ROOT/Sources/mongshell-menubar"
echo "▶ compiling openclaw client tests"
swiftc -o "$OUT/client-tests" \
  "$APP/Design/Palette.swift" \
  "$APP/Models/OpenClawHealth.swift" \
  "$APP/Models/OpenClawStatus.swift" \
  "$APP/Services/OpenClawStatusClient.swift" \
  "$AGENT/Probe.swift" \
  "$AGENT/StatusFile.swift" \
  "$ROOT/Tests/OpenClawClientTests/main.swift"

echo "▶ running openclaw client tests"
"$OUT/client-tests"
