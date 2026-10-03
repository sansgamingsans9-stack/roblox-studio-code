#!/usr/bin/env bash
# Runs the offline tests with the `luau` CLI:
#   * unit tests for the pure modules (Shapes, SnowField, StampCodec)
#   * end-to-end tests of the real client code against a small Roblox engine mock
# Roblox-style `require(script.Parent.X)` is rewritten to `require("./X")` in a temp copy and the
# mock's globals (game, Vector3, task, ...) are injected at the top of every module.
#   LUAU=/path/to/luau tools/test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUAU="${LUAU:-luau}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/mods"
GLOBALS="game, Enum, Vector3, Vector2, CFrame, Color3, ColorSequence, NumberSequence, NumberSequenceKeypoint, NumberRange, Instance, RaycastParams, OverlapParams, Content, task, warn, shared, os, UserSettings"
INJECT="local __rbx = require(\"../rbxmock\"); local $GLOBALS = __rbx.game, __rbx.Enum, __rbx.Vector3, __rbx.Vector2, __rbx.CFrame, __rbx.Color3, __rbx.ColorSequence, __rbx.NumberSequence, __rbx.NumberSequenceKeypoint, __rbx.NumberRange, __rbx.Instance, __rbx.RaycastParams, __rbx.OverlapParams, __rbx.Content, __rbx.task, __rbx.warn, __rbx.shared, __rbx.os, __rbx.UserSettings"
for f in "$ROOT"/src/DeformableSnow/*.luau; do
	m="$(basename "$f")"
	case "$m" in *.client.luau|*.server.luau) continue ;; esac
	{
		echo "$INJECT"
		sed -E 's/require\(script\.Parent\.([A-Za-z]+)\)/require(".\/\1")/g' "$f"
	} > "$WORK/mods/$m"
done
cp "$ROOT"/tests/*.luau "$WORK/"

status=0
for spec in "$WORK"/*.spec.luau; do
	if ! out="$(timeout "${SPEC_TIMEOUT:-120}" "$LUAU" "$spec" 2>&1)"; then
		out="$out
$(basename "$spec"): FAILED (error or timeout)"
		status=1
	fi
	echo "$out"
	if echo "$out" | grep -q "FAIL\|error"; then
		status=1
	fi
done
exit $status
