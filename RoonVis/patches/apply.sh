#!/usr/bin/env bash
# Apply the local tvOS/GLES compatibility patches to the vendored projectM
# submodules. These patches are small, documented build-script edits required
# to build libprojectM v4.1.0 for tvOS via ANGLE (see GATE_STEP_B.md). They are
# kept as patch files rather than committed into the submodules so the recorded
# submodule pointers stay on the clean upstream tags.
#
# Idempotent: re-running is a no-op once applied. Run from anywhere.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PM="$REPO_ROOT/vendor/projectm"
PME="$PM/vendor/projectm-eval"
ANGLE="$REPO_ROOT/vendor/angle"

apply_patch() {
  local dir="$1" patch="$2"
  if [ ! -d "$dir" ]; then
    echo "error: $dir not found — run 'git submodule update --init --recursive' first" >&2
    exit 1
  fi
  if git -C "$dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "already applied: $(basename "$patch")"
  else
    git -C "$dir" apply "$patch"
    echo "applied: $(basename "$patch")"
  fi
}

apply_patch "$PM"  "$REPO_ROOT/RoonVis/patches/projectm.patch"
apply_patch "$PME" "$REPO_ROOT/RoonVis/patches/projectm-eval.patch"
apply_patch "$ANGLE" "$REPO_ROOT/RoonVis/patches/angle-es3-legacy-gpu.patch"
echo "done"
