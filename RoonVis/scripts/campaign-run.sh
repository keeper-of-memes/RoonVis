#!/bin/bash
# campaign-run.sh — W1 campaign harness: one invocation = one on-device launch
# session with every guard (reachability/reboot-when-asleep, cooldown gate,
# log wipe, launch check, FixedRotation resolve verification, growth watchdog,
# CompatBurnIn harvest). Distills the proven gl-mechanism-run.sh /
# hd-campaign-tick.sh idioms; per-session only (batching is out of scope).
#
# Usage:
#   campaign-run.sh --device <udid> [--bundle-id <id>]
#                   [--presets <file-or-inline-pipe-joined>]
#                   [--env ROONVIS_KEY=VAL]...
#                   [--pulls N] [--pull-interval S] [--duration SECS]
#                   [--out DIR] [--workdir DIR] [--stamp-dir DIR]
#                   [--cooldown-secs N] [--thermal-probe]
#                   [--allow-reboot | --no-reboot] [--dry-run]
#
# Examples:
#   campaign-run.sh --device <APPLE_TV_UDID> \
#     --presets /tmp/batch.txt \
#     --env ROONVIS_COMPAT_BURNIN=1 --env ROONVIS_HD_FULL_CATALOG=1 \
#     --env ROONVIS_DISABLE_SLOW_PRESET_SKIP=1 --env ROONVIS_DISABLE_SNAPCAST=1 \
#     --env ROONVIS_ROTATION_SECONDS=30 --duration 1500 --out /tmp/w1-run
#
#   CAMPAIGN_DEVICE=<APPLE_TV_UDID> campaign-run.sh --presets 'a.milk|b.milk' --dry-run
#
# Exit codes: 0 ok, 1 usage error, 2 launch failed, 3 resolve mismatch,
#             4 log stalled, 5 thermal/cooldown gate, 6 device unreachable.
set -u

DEVICE_LOG_PATH="Library/Caches/perf-diagnostics.log"

ts() { date +%T; }
log() { echo "[$(ts)] $*"; }
die_usage() { echo "ERROR: $*" >&2; exit 1; }

# ---- defaults ---------------------------------------------------------------
DEVICE="${CAMPAIGN_DEVICE:-}"
BUNDLE_ID="local.roon-vis.gate-step-a"
PRESETS_ARG=""
ENV_KVS=()
PULLS=17
PULL_INTERVAL=90
DURATION=""
OUT=""
WORKDIR=""
STAMP_DIR="/tmp/roonvis-campaign-stamps"
COOLDOWN_SECS=900
THERMAL_PROBE=0
ALLOW_REBOOT=1
DRY_RUN=0
RESOLVE_TOLERANCE=0

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ---- argument parsing -------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --device)         [ $# -ge 2 ] || die_usage "--device needs a value"; DEVICE="$2"; shift 2 ;;
    --bundle-id)      [ $# -ge 2 ] || die_usage "--bundle-id needs a value"; BUNDLE_ID="$2"; shift 2 ;;
    --presets)        [ $# -ge 2 ] || die_usage "--presets needs a value"; PRESETS_ARG="$2"; shift 2 ;;
    --env)            [ $# -ge 2 ] || die_usage "--env needs KEY=VAL"; ENV_KVS+=("$2"); shift 2 ;;
    --pulls)          [ $# -ge 2 ] || die_usage "--pulls needs a value"; PULLS="$2"; shift 2 ;;
    --pull-interval)  [ $# -ge 2 ] || die_usage "--pull-interval needs a value"; PULL_INTERVAL="$2"; shift 2 ;;
    --duration)       [ $# -ge 2 ] || die_usage "--duration needs a value"; DURATION="$2"; shift 2 ;;
    --out)            [ $# -ge 2 ] || die_usage "--out needs a value"; OUT="$2"; shift 2 ;;
    --workdir)        [ $# -ge 2 ] || die_usage "--workdir needs a value"; WORKDIR="$2"; shift 2 ;;
    --stamp-dir)      [ $# -ge 2 ] || die_usage "--stamp-dir needs a value"; STAMP_DIR="$2"; shift 2 ;;
    --cooldown-secs)  [ $# -ge 2 ] || die_usage "--cooldown-secs needs a value"; COOLDOWN_SECS="$2"; shift 2 ;;
    --resolve-tolerance) [ $# -ge 2 ] || die_usage "--resolve-tolerance needs a value"; RESOLVE_TOLERANCE="$2"; shift 2 ;;
    --thermal-probe)  THERMAL_PROBE=1; shift ;;
    --allow-reboot)   ALLOW_REBOOT=1; shift ;;
    --no-reboot)      ALLOW_REBOOT=0; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        sed -n '2,29p' "$0"; exit 0 ;;
    *)                die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$DEVICE" ] || die_usage "--device <udid> is required (or set CAMPAIGN_DEVICE)"
is_uint "$PULLS" || die_usage "--pulls must be a positive integer"
is_uint "$PULL_INTERVAL" || die_usage "--pull-interval must be a positive integer"
is_uint "$RESOLVE_TOLERANCE" || die_usage "--resolve-tolerance must be a non-negative integer"
is_uint "$COOLDOWN_SECS" || die_usage "--cooldown-secs must be a non-negative integer"
[ "$PULLS" -ge 1 ] || die_usage "--pulls must be >= 1"
[ "$PULL_INTERVAL" -ge 1 ] || die_usage "--pull-interval must be >= 1"
if [ -n "$DURATION" ]; then
  is_uint "$DURATION" || die_usage "--duration must be a positive integer (seconds)"
  [ "$DURATION" -ge 1 ] || die_usage "--duration must be >= 1"
  PULLS=$(( (DURATION + PULL_INTERVAL - 1) / PULL_INTERVAL ))
  [ "$PULLS" -ge 1 ] || PULLS=1
fi

# ---- extra env (--env KEY=VAL, ROONVIS_ keys only) --------------------------
if [ "${#ENV_KVS[@]}" -gt 0 ]; then
  for kv in "${ENV_KVS[@]}"; do
    case "$kv" in
      *=*) : ;;
      *) die_usage "--env expects KEY=VAL, got: $kv" ;;
    esac
    key="${kv%%=*}"
    val="${kv#*=}"
    case "$key" in
      ROONVIS_*) : ;;
      *) die_usage "--env keys must start with ROONVIS_, got: $key" ;;
    esac
    export "DEVICECTL_CHILD_${key}=${val}"
  done
fi

# ---- preset list (file = one name per line; env value is ALWAYS |-joined
#      because preset filenames contain commas; the app parser prefers '|') ---
PRESET_LIST=""
PRESET_COUNT=0
if [ -n "$PRESETS_ARG" ]; then
  if [ -f "$PRESETS_ARG" ]; then
    PRESET_LIST=$(grep -v '^[[:space:]]*$' "$PRESETS_ARG" | paste -s -d'|' -)
  else
    PRESET_LIST="$PRESETS_ARG"
  fi
  [ -n "$PRESET_LIST" ] || die_usage "--presets resolved to an empty list"
  PRESET_COUNT=$(printf '%s\n' "$PRESET_LIST" | awk -F'|' '{n=0; for (i=1; i<=NF; i++) if ($i ~ /[^ \t]/) n++; print n}')
  [ "$PRESET_COUNT" -ge 1 ] || die_usage "--presets resolved to an empty list"
  export "DEVICECTL_CHILD_ROONVIS_ROTATION_FIXED_LIST=${PRESET_LIST}"
fi

# ---- output dir -------------------------------------------------------------
if [ -z "$OUT" ]; then
  base="${WORKDIR:-${TMPDIR:-/tmp}}"
  OUT="${base%/}/campaign-$(date +%Y%m%d-%H%M%S)"
fi
DEVICE_LOG="$OUT/device.log"
OUTCOMES="$OUT/outcomes.txt"
MANIFEST="$OUT/run-manifest.txt"
STAMP_FILE="${STAMP_DIR%/}/campaign-last-end.${DEVICE}.epoch"

resolved_child_env() { env | LC_ALL=C grep '^DEVICECTL_CHILD_' | LC_ALL=C sort; }

# ---- thermal probe (interface reserved) --------------------------------------
if [ "$THERMAL_PROBE" -eq 1 ]; then
  log "thermal probe: not implemented (TODO) — continuing (the app logs 'Thermal: state=' at startup)"
fi

# ---- dry run: resolved env + plan, no device I/O, no stamp -------------------
if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN — no device I/O will be performed"
  echo "device:        $DEVICE"
  echo "bundle-id:     $BUNDLE_ID"
  echo "out:           $OUT"
  echo "pulls:         $PULLS x ${PULL_INTERVAL}s (~$((PULLS * PULL_INTERVAL))s)"
  echo "cooldown:      ${COOLDOWN_SECS}s (stamp: $STAMP_FILE)"
  echo "allow-reboot:  $ALLOW_REBOOT"
  echo "preset count:  $PRESET_COUNT"
  if [ -f "$STAMP_FILE" ]; then
    last=$(cat "$STAMP_FILE" 2>/dev/null || echo 0)
    is_uint "$last" || last=0
    age=$(( $(date +%s) - last ))
    if [ "$age" -lt "$COOLDOWN_SECS" ]; then
      echo "cooldown gate: WOULD BLOCK ($((COOLDOWN_SECS - age))s remaining)"
    else
      echo "cooldown gate: would pass (last end ${age}s ago)"
    fi
  else
    echo "cooldown gate: would pass (no stamp)"
  fi
  echo "resolved DEVICECTL_CHILD_ env:"
  resolved_child_env | sed 's/^/  /'
  exit 0
fi

# Stamp the campaign end time on ALL device-touching exit paths (trap EXIT) so
# the next invocation's cooldown gate sees it. The one exception is the cooldown
# rejection itself (rc=5): stamping a rejected attempt would push its own gate
# forward forever.
on_exit() {
  rc=$?
  if [ "$rc" -ne 5 ]; then
    mkdir -p "$STAMP_DIR" 2>/dev/null
    date +%s > "$STAMP_FILE" 2>/dev/null
  fi
  log "exit rc=$rc (cooldown stamp: $STAMP_FILE)"
  exit "$rc"
}
trap on_exit EXIT

# ---- 1. preflight reachability (NEVER reboot a reachable device) -------------
if xcrun devicectl device info details --device "$DEVICE" >/dev/null 2>&1; then
  log "device reachable, no reboot needed"
else
  if [ "$ALLOW_REBOOT" -ne 1 ]; then
    log "device unreachable and --no-reboot set — aborting"
    exit 6
  fi
  log "device unreachable — rebooting to wake..."
  xcrun devicectl device reboot --device "$DEVICE" >/dev/null 2>&1
  up=0
  for i in $(seq 1 40); do
    sleep 6
    if xcrun devicectl device info details --device "$DEVICE" >/dev/null 2>&1; then
      log "device up after ~$((i * 6))s"
      up=1
      break
    fi
  done
  if [ "$up" -ne 1 ]; then
    log "device still unreachable after reboot + 240s — aborting"
    exit 6
  fi
  sleep 8
fi

# ---- 2. cooldown gate (exit 5; on_exit skips the stamp for rc=5) -------------
if [ -f "$STAMP_FILE" ] && [ "$COOLDOWN_SECS" -gt 0 ]; then
  last=$(cat "$STAMP_FILE" 2>/dev/null || echo 0)
  is_uint "$last" || last=0
  age=$(( $(date +%s) - last ))
  if [ "$age" -lt "$COOLDOWN_SECS" ]; then
    log "cooldown gate: last campaign ended ${age}s ago (< ${COOLDOWN_SECS}s) — wait $((COOLDOWN_SECS - age))s"
    exit 5
  fi
fi

mkdir -p "$OUT" || { log "cannot create --out dir $OUT"; exit 1; }

# ---- 3. wipe the on-device diagnostics log so this run's data is unambiguous -
xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" --source /dev/null \
  --destination "$DEVICE_LOG_PATH" >/dev/null 2>&1
log "wiped on-device $DEVICE_LOG_PATH"

# ---- 4. launch (env passes via DEVICECTL_CHILD_ prefix in the PARENT env) ----
{
  echo "started:       $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "device:        $DEVICE"
  echo "bundle-id:     $BUNDLE_ID"
  echo "out:           $OUT"
  echo "pulls:         $PULLS x ${PULL_INTERVAL}s (~$((PULLS * PULL_INTERVAL))s)"
  echo "cooldown-secs: $COOLDOWN_SECS"
  echo "allow-reboot:  $ALLOW_REBOOT"
  echo "preset count:  $PRESET_COUNT"
  echo "preset list:   ${PRESET_LIST:-(none - app-side rotation)}"
  echo "DEVICECTL_CHILD_ env:"
  resolved_child_env | sed 's/^/  /'
} > "$MANIFEST"
log "manifest: $MANIFEST"

log "launching $BUNDLE_ID..."
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" 2>&1 | tail -3
LAUNCH_RC=${PIPESTATUS[0]}
if [ "$LAUNCH_RC" -ne 0 ]; then
  log "LAUNCH FAILED rc=$LAUNCH_RC — aborting"
  exit 2
fi

# ---- 5+6. monitor loop: pull, verify resolve (first 2 pulls), watch growth ---
pull_device_log() {
  xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --source "$DEVICE_LOG_PATH" \
    --destination "$DEVICE_LOG" >/dev/null 2>&1
}

print_unresolved_if_present() {
  unresolved=$(grep 'FixedRotationUnresolved:' "$DEVICE_LOG" 2>/dev/null | tail -1)
  if [ -n "$unresolved" ]; then
    log "$unresolved"
  fi
}

prev=0
resolve_verified=0
i=1
while [ "$i" -le "$PULLS" ]; do
  sleep "$PULL_INTERVAL"
  pull_device_log
  cur=$(wc -l < "$DEVICE_LOG" 2>/dev/null | tr -d '[:space:]')
  is_uint "$cur" || cur=0
  outcomes=$(grep -c 'CompatBurnIn: preset=' "$DEVICE_LOG" 2>/dev/null)
  is_uint "$outcomes" || outcomes=0
  log "pull $i/$PULLS: $cur lines (+$((cur - prev))), $outcomes burn-in outcomes"

  # Resolve verification: the app mirrors 'FixedRotation: requested=m resolved=n'
  # into the sink at startup; require it within the first 2 pulls and require
  # n == m == our own count before burning the whole session.
  if [ -n "$PRESET_LIST" ] && [ "$resolve_verified" -ne 1 ]; then
    line=$(grep -E 'FixedRotation: requested=[0-9]+ resolved=[0-9]+' "$DEVICE_LOG" 2>/dev/null | tail -1)
    if [ -n "$line" ]; then
      req=$(printf '%s\n' "$line" | sed -E 's/.*requested=([0-9]+).*/\1/')
      res=$(printf '%s\n' "$line" | sed -E 's/.*resolved=([0-9]+).*/\1/')
      # Tolerance: presets that crashed the app in an earlier session enter the
      # app's self-healing crash blocklist and stop resolving — a small deficit
      # is expected campaign data (the caller quarantines the named drops from
      # the FixedRotationUnresolved line), not a mis-set list. A LARGE deficit,
      # a surplus, or a sent-count mismatch still aborts.
      deficit=$((req - res))
      if [ "$req" != "$PRESET_COUNT" ] || [ "$deficit" -lt 0 ] || [ "$deficit" -gt "$RESOLVE_TOLERANCE" ]; then
        log "RESOLVE MISMATCH: requested=$req resolved=$res expected=$PRESET_COUNT tolerance=$RESOLVE_TOLERANCE — aborting"
        print_unresolved_if_present
        exit 3
      fi
      resolve_verified=1
      if [ "$deficit" -gt 0 ]; then
        log "resolve verified WITH DEFICIT $deficit: requested=$req resolved=$res (within tolerance $RESOLVE_TOLERANCE)"
        print_unresolved_if_present
      else
        log "resolve verified: requested=$req resolved=$res (matches sent list)"
      fi
    elif [ "$i" -ge 2 ]; then
      log "RESOLVE MISSING: no 'FixedRotation:' line after $i pulls — aborting"
      print_unresolved_if_present
      exit 3
    fi
  fi

  # Growth watchdog (from pull 3): a stalled tiny log means the app died or
  # never opened the sink.
  if [ "$i" -ge 3 ] && [ "$cur" -le "$prev" ] && [ "$cur" -lt 20 ]; then
    log "LOG NOT GROWING ($cur lines) — app not running? aborting"
    exit 4
  fi
  prev=$cur
  i=$((i + 1))
done

# ---- 7. harvest: dedupe CompatBurnIn lines, LAST occurrence per preset wins ---
grep 'CompatBurnIn: preset=' "$DEVICE_LOG" 2>/dev/null | awk '
  {
    name = $0
    sub(/.*preset=/, "", name)
    sub(/ maxRenderMs=.*/, "", name)
    if (!(name in seen)) { order[++n] = name; seen[name] = 1 }
    last[name] = $0
  }
  END { for (j = 1; j <= n; j++) print last[order[j]] }
' > "$OUTCOMES"

total=$(wc -l < "$OUTCOMES" | tr -d '[:space:]')
log "harvest: $total unique preset outcomes -> $OUTCOMES"
log "outcome summary:"
sed -n 's/.*outcome=\([a-z]*\).*/\1/p' "$OUTCOMES" | sort | uniq -c | sed 's/^/  /'
log "DONE"
exit 0
