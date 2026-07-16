#!/usr/bin/env bash
# build-health.sh — quality gate for RoonVis.
#
# Modes:
#   --host-only   configure + build + run the pure-C++ host test suite, then guardrail greps.
#   (default)     host-only steps PLUS Debug and Release simulator app builds.
#
# Both modes end with GUARDRAIL GREPS. NOTE: this check is ADVISORY (whole-file
# allowlist — it cannot catch new default-access sites added inside already-allowlisted
# files; function-scoped enforcement is tracked for W8). GUARDRAILS_HARD=1 makes new
# non-allowlisted FILES fail the gate.
#
# Env overrides:
#   SKIP_APP_BUILDS=1   force-skip the sim app builds even in default mode.
set -euo pipefail

# --- tunables -------------------------------------------------------------------------
# Bump HOST_TEST_FLOOR as new host suites land (never let it drift below the real count).
HOST_TEST_FLOOR=1511
# Report-only guardrails for now. Set to 1 to make NEW default-read sites fail the gate.
GUARDRAILS_HARD=1

# --- locations ------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

HOST_BUILD_DIR="RoonVis/build-host-tests"
HOST_TEST_BIN="${HOST_BUILD_DIR}/RoonVisTests"
XCODEPROJ="RoonVis/RoonVis.xcodeproj"
ALLOWLIST="RoonVis/scripts/guardrail-allowlist.txt"
SOURCES_DIR="RoonVis/Sources"
SIM_DEST='platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'

# --- arg parse ------------------------------------------------------------------------
MODE="full"
case "${1:-}" in
  --host-only) MODE="host-only" ;;
  "" )         MODE="full" ;;
  * ) echo "usage: $0 [--host-only]" >&2; exit 2 ;;
esac

FAILURES=0
fail()  { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
info()  { echo ">>> $*"; }

# --- host tests -----------------------------------------------------------------------
run_host_tests() {
  info "Configuring host tests..."
  cmake -S RoonVis -B "${HOST_BUILD_DIR}" -DROONVIS_BUILD_APP=OFF -DROONVIS_BUILD_TESTS=ON

  info "Building RoonVisTests..."
  cmake --build "${HOST_BUILD_DIR}" --target RoonVisTests

  info "Running host test suite..."
  local out
  out="$("${HOST_TEST_BIN}")"
  echo "${out}"

  # Parse the final "N passed, M failed" line.
  local summary passed failed
  summary="$(echo "${out}" | grep -E '[0-9]+ passed, [0-9]+ failed' | tail -1)"
  if [[ -z "${summary}" ]]; then
    fail "could not find 'N passed, M failed' summary line in test output"
    return
  fi
  passed="$(echo "${summary}" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')"
  failed="$(echo "${summary}" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')"

  if (( failed > 0 )); then
    fail "host tests reported ${failed} failing checks"
  fi
  if (( passed < HOST_TEST_FLOOR )); then
    fail "host test count ${passed} < floor ${HOST_TEST_FLOOR} (suite shrank? bump the floor only when intentional)"
  fi
  if (( failed == 0 && passed >= HOST_TEST_FLOOR )); then
    info "host tests OK: ${passed} passed (floor ${HOST_TEST_FLOOR}), 0 failed"
  fi
}

# --- app sim builds -------------------------------------------------------------------
run_app_builds() {
  if [[ "${SKIP_APP_BUILDS:-0}" == "1" ]]; then
    echo "SKIPPED: app sim builds (SKIP_APP_BUILDS=1)"
    return
  fi
  if [[ ! -e "${XCODEPROJ}" ]]; then
    echo "SKIPPED: app sim builds (${XCODEPROJ} not present — run cmake -G Xcode to generate it)"
    return
  fi
  local cfg
  for cfg in Debug Release; do
    info "Building app (${cfg}, tvOS simulator)..."
    if xcodebuild -project "${XCODEPROJ}" -scheme RoonVis -configuration "${cfg}" \
        -destination "${SIM_DEST}" -derivedDataPath .derived-data \
        -quiet build; then
      info "app ${cfg} build OK"
    else
      fail "app ${cfg} simulator build failed"
    fi
  done
}

# --- guardrail greps (ADVISORY; hard-fails new files when GUARDRAILS_HARD=1) -----------
# ADVISORY (whole-file allowlist — cannot catch new sites inside allowlisted files;
# function-scoped enforcement tracked for W8). Returns count of NEW (non-allowlisted)
# FILES via the global GUARDRAIL_HITS.
guardrails() {
  echo ""
  echo "=== GUARDRAIL GREPS — ADVISORY (whole-file allowlist — cannot catch new sites inside allowlisted files; function-scoped enforcement tracked for W8); GUARDRAILS_HARD=${GUARDRAILS_HARD} ==="
  GUARDRAIL_HITS=0

  # Build a grep -f exclude pattern from the allowlist (path substrings). Skip blanks/#.
  local allow_tmp
  allow_tmp="$(mktemp)"
  if [[ -f "${ALLOWLIST}" ]]; then
    grep -vE '^\s*(#|$)' "${ALLOWLIST}" > "${allow_tmp}" || true
  fi

  # (a) persistent-domain / synchronize writes.
  local pat_a='persistentDomainForName|synchronize\]'
  # (b) NSUserDefaults READS.
  local pat_b='objectForKey|stringForKey|integerForKey|doubleForKey|boolForKey|arrayForKey'

  local check
  for check in "domain/synchronize:${pat_a}" "defaults-read:${pat_b}"; do
    local label="${check%%:*}"
    local pat="${check#*:}"
    # Files containing the pattern, minus allowlisted path-substrings.
    local hits
    hits="$(grep -rlE "${pat}" "${SOURCES_DIR}" 2>/dev/null | { grep -vF -f "${allow_tmp}" || true; })"
    if [[ -n "${hits}" ]]; then
      while IFS= read -r f; do
        [[ -z "${f}" ]] && continue
        echo "WARN: [${label}] NEW default-access site not in allowlist: ${f}"
        GUARDRAIL_HITS=$((GUARDRAIL_HITS + 1))
      done <<< "${hits}"
    fi
  done

  rm -f "${allow_tmp}"

  if (( GUARDRAIL_HITS == 0 )); then
    echo "guardrails: OK — no default-access sites outside the allowlist"
  else
    echo "guardrails: ${GUARDRAIL_HITS} NEW site(s) flagged above"
    if [[ "${GUARDRAILS_HARD}" == "1" ]]; then
      fail "guardrails: ${GUARDRAIL_HITS} NEW default-access site(s) (GUARDRAILS_HARD=1)"
    fi
  fi
  # This section never exits nonzero on its own while GUARDRAILS_HARD=0.
}

# --- run ------------------------------------------------------------------------------
echo "=== build-health.sh (mode: ${MODE}) ==="
run_host_tests
if [[ "${MODE}" == "full" ]]; then
  run_app_builds
fi
guardrails

echo ""
echo "======================================"
if (( FAILURES == 0 )); then
  echo "PASS: build-health (${MODE}) — all gates green"
  exit 0
else
  echo "FAIL: build-health (${MODE}) — ${FAILURES} gate(s) failed"
  exit 1
fi
