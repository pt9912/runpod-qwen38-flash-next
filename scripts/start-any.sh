#!/usr/bin/env bash
# Gets ONE Pod of the pool running: first tries to start the stopped pool Pods one after the
# other (each on its own machine; a failed try costs nothing), and if none can start, creates
# a new Pod (any machine with a free B200) while the pool is smaller than POOL_MAX. It never
# lets two pool Pods run: if one is already RUNNING/STARTING/PROVISIONING it does nothing.
#
# Pool = every Pod whose name starts with POOL_PREFIX (default qwen3.8-flash-next-b200), not TERMINATED.
# New Pods get unique names (qwen3.8-flash-next-b200, qwen3.8-flash-next-b200-2, ...). Why restart before
# creating: the measured restart on the old machine (5:56 min) was faster than a new Pod (10:09 min).
#
# A SUCCESS BILLS THE GPU from that moment on. A failed try creates or starts
# nothing. Only "GPU occupied"/"no capacity" (exit 5) and a temporarily unreadable Pod (exit 6)
# are retried; anything else stops at once, so a possibly started or created Pod is never
# retried. If a created Pod FAILS verification, create-pod.sh stops and renames it (or terminates
# it as a fallback) and the script stops; if the verification could not run, the Pod is left running.
#
# Usage: start-any.sh [--no-create] [--dry-run] [--wait] [MAX_WAIT_SECONDS] [INTERVAL_SECONDS]
#   MAX_WAIT_SECONDS  attempts begin for at most this long (default 1200). An attempt already running
#                     is not cut off: each pool Pod tried costs up to three API calls of up to 60 s, so
#                     the last round can end minutes later with many Pods.   INTERVAL_SECONDS  between
#                     rounds, >= 30 (default 30); a round makes about 5 + 3N API calls (N = stopped Pods)
#   --no-create  only start existing Pods, never create one
#   --dry-run    show the pool and what would be tried; start and create nothing
#   --wait       afterwards run wait-for-ready.sh for the running Pod (measures the time to ready)
# Environment: POOL_PREFIX (default qwen3.8-flash-next-b200), POOL_MAX (default 6), NETWORK_VOLUME_ID etc. as
#   for create-pod.sh (CREATE_POD_SSH=1 makes new Pods expose ssh); READY_TIMEOUT (seconds, default 3600) for --wait
#
# Only ONE start-any.sh (or create-pod.sh --yes) can run at a time on this machine (a kernel file
# lock, released even if the script is killed); a second one exits with code 4 and starts/creates nothing.
#
# Exit codes: 0 = a pool Pod is running (started, created, or already running), 3 = gave up (nothing
#   running), 4 = another start/create is in progress, 130 = interrupted, 2 = bad arguments,
#   7 = with --wait: a Pod IS running (and billing) but wait-for-ready.sh did not confirm readiness,
#   1 = any other failure (message shown; a created Pod that failed verification counts here: it
#   is stopped and renamed to failed-..., see create-pod.sh).
set -uo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"
# shellcheck source=scripts/_pool.sh
source "$HERE/_pool.sh"

CREATE=1; DRY=0; WAIT=0; NUMS=()
for a in "$@"; do
  case "$a" in
    --no-create) CREATE=0 ;; --dry-run) DRY=1 ;; --wait) WAIT=1 ;;
    -*) echo "unknown argument: $a (see the header of this script)" >&2; exit 2 ;;
    *) NUMS+=("$a") ;;
  esac
done
[ "${#NUMS[@]}" -le 2 ] || { echo "too many arguments" >&2; exit 2; }
MAX_WAIT="${NUMS[0]:-1200}"; INTERVAL="${NUMS[1]:-30}"; POOL_MAX="${POOL_MAX:-6}"
case "$MAX_WAIT$INTERVAL$POOL_MAX" in ''|*[!0-9]*) echo "MAX_WAIT_SECONDS, INTERVAL_SECONDS and POOL_MAX must be whole numbers" >&2; exit 2 ;; esac
[ "${#MAX_WAIT}" -le 9 ] && [ "${#INTERVAL}" -le 9 ] && [ "${#POOL_MAX}" -le 3 ] || { echo "numbers too long" >&2; exit 2; }
MAX_WAIT=$((10#$MAX_WAIT)); INTERVAL=$((10#$INTERVAL)); POOL_MAX=$((10#$POOL_MAX))
[ "$INTERVAL" -ge "${START_MIN_INTERVAL:-30}" ] || { echo "INTERVAL must be >= 30 s (API rate limit)" >&2; exit 2; }
[ "$POOL_MAX" -ge 1 ] || { echo "POOL_MAX must be >= 1" >&2; exit 2; }

tmp="$(mktemp)"; child=""
trap 'rm -f "$tmp"; pool_lock_release' EXIT
on_signal() {
  # Job cancelled: stop the running attempt (prevents a request that has not been sent yet), but say
  # clearly that one that was already sent cannot be undone.
  [ -z "$child" ] || kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null
  echo >&2
  echo "Interrupted. If a start or create request had already been sent, a Pod may be starting or exist (and bill): check with scripts/v2-smoke.sh." >&2
  exit 130
}
trap on_signal INT TERM

# run_child CMD...: run in its own process group; sets RC and OUT.
run_child() {
  set -m
  # stdin closed: a child must never eat the lines of the loop that calls us; fd 9 closed: a child (or
  # anything it leaves running) must never keep the lock alive after this script is gone.
  "$@" >"$tmp" 2>&1 </dev/null 8>&- 9>&- &
  child=$!
  set +m
  wait "$child"; RC=$?; child=""
  OUT="$(cat "$tmp")"
}

finish() {   # finish ID NAME HOW
  echo
  echo "Running Pod: $2 ($1) $3"
  echo "  URL: https://$1-8000.proxy.runpod.net"
  echo "  Use: RUNPOD_POD_ID=$1   QWEN_URL=https://$1-8000.proxy.runpod.net"
  if [ "$WAIT" -eq 1 ]; then
    # A QWEN_URL exported from .env would point at another Pod and take precedence: drop it, use this Pod.
    # In the background, so that a SIGTERM to this script is handled at once instead of after the wait.
    env -u QWEN_URL RUNPOD_POD_ID="$1" "$HERE/wait-for-ready.sh" "${READY_TIMEOUT:-3600}" 10 8>&- 9>&- &
    child=$!
    wait "$child"; wrc=$?
    child=""
    if [ "$wrc" -ne 0 ]; then
      echo "Pod $2 ($1) IS RUNNING and billing, but wait-for-ready.sh did not confirm readiness (its exit code was $wrc)." >&2
      echo "Check it, or stop it: scripts/stop-any.sh" >&2
      exit 7
    fi
    exit 0
  fi
  exit 0
}

# ---------------------------------------------------------------- dry run
if [ "$DRY" -eq 1 ]; then
  pool_refresh || { printf '%s\n' "$POOL_ERR" >&2; echo "Could not list Pods." >&2; exit 1; }
  echo "Pool '$POOL_PREFIX*': $(pool_count) of $POOL_MAX"
  printf '%s' "$POOL_MEMBERS" | while IFS=$'\t' read -r id name status; do [ -z "$id" ] || printf '  %-28s %-16s %s\n' "$name" "$id" "$status"; done
  if act="$(pool_active)"; then
    IFS=$'\t' read -r id name status <<<"$act"; echo "DRY RUN: '$name' ($id) is already $status; nothing would be done."; exit 0
  fi
  echo "DRY RUN: would try to start, in this order:"
  pool_candidates | while IFS=$'\t' read -r id name status; do printf '  %s (%s)\n' "$name" "$id"; done
  if [ "$CREATE" -eq 0 ]; then echo "  (--no-create: no new Pod)"
  elif [ "$(pool_count)" -ge "$POOL_MAX" ]; then echo "  no new Pod: the pool is full ($POOL_MAX)"
  else echo "  then create a new Pod named '$(pool_pick_name)'"; fi
  echo "DRY RUN: nothing was started or created."
  exit 0
fi

# ---------------------------------------------------------------- lock + main loop
pool_lock_acquire || { echo "Another start-any.sh / create-pod.sh is in progress on this machine (PID ${POOL_LOCK_HOLDER:-?}, lock $POOL_LOCKFILE). Nothing was started or created." >&2; exit 4; }
export POOL_LOCK_HELD=1   # create-pod.sh (child) must not try to take the lock again
start=$SECONDS; attempt=0; read_failures=0; full_noted=0
echo "Getting a '$POOL_PREFIX*' Pod running (attempts begin for up to ${MAX_WAIT}s, every ${INTERVAL}s; pool max $POOL_MAX; create: $([ "$CREATE" -eq 1 ] && echo yes || echo no))."
while true; do
  if [ "$attempt" -gt 0 ] && [ $((SECONDS - start)) -ge "$MAX_WAIT" ]; then
    echo "Gave up after ${MAX_WAIT}s and $attempt round(s): no pool Pod could be started or created. Nothing is running." >&2
    exit 3
  fi
  attempt=$((attempt + 1))

  if ! pool_refresh; then
    read_failures=$((read_failures + 1))
    printf '%s\n' "$POOL_ERR" >&2
    if [ "$read_failures" -ge 10 ]; then echo "The Pod list could not be read 10 times in a row; giving up. Nothing was started." >&2; exit 1; fi
    echo "[$(date +%H:%M:%S)] round $attempt: could not read the Pod list (temporary?), nothing sent"
  else
    read_failures=0
    # Guard: never a second Pod.
    if act="$(pool_active)"; then IFS=$'\t' read -r id name status <<<"$act"; finish "$id" "$name" "(already $status, nothing started)"; fi

    # 1. Restart existing Pods, most recently used first.
    started=""
    while IFS=$'\t' read -r id name status; do
      [ -n "$id" ] || continue
      run_child env RUNPOD_POD_ID="$id" "$HERE/pod-start.sh"
      case "$RC" in
        0) finish "$id" "$name" "(restarted)" ;;
        5) echo "[$(date +%H:%M:%S)] round $attempt: '$name' ($id): its machine is occupied" ;;
        6) echo "[$(date +%H:%M:%S)] round $attempt: '$name' ($id): could not be read, skipped" ;;
        8) printf '%s\n' "$OUT" >&2; echo "[$(date +%H:%M:%S)] round $attempt: '$name' ($id): rejected (nothing sent or changed), skipped" ;;
        *) printf '%s\n' "$OUT" >&2; echo "Starting '$name' ($id) failed (exit $RC); stopping, nothing else is tried." >&2; exit "$RC" ;;
      esac
    done < <(pool_candidates)

    # 2. Create a new Pod (any machine with a free B200) while the pool has room.
    if [ "$CREATE" -eq 1 ]; then
      if pool_refresh && [ "$(pool_count)" -lt "$POOL_MAX" ]; then
        if act="$(pool_active)"; then IFS=$'\t' read -r id name status <<<"$act"; finish "$id" "$name" "(already $status, nothing created)"; fi
        newname="$(pool_pick_name)"
        run_child env POD_NAME="$newname" "$HERE/create-pod.sh" --yes
        case "$RC" in
          0)
            printf '%s\n' "$OUT"
            newid="$(printf '%s\n' "$OUT" | sed -n 's/^Created Pod \([^ ]*\)\. It is billing now\.$/\1/p' | head -n1)"
            if [ -z "$newid" ]; then   # fall back to a lookup by name
              pool_refresh && newid="$(printf '%s' "$POOL_MEMBERS" | awk -F'\t' -v n="$newname" '$2 == n { print $1; exit }')"
            fi
            finish "${newid:-?}" "$newname" "(newly created)"
            ;;
          5) echo "[$(date +%H:%M:%S)] round $attempt: no capacity for a new Pod ('$newname')" ;;
          6)
            printf '%s\n' "$OUT" >&2
            echo "A Pod '$newname' was created and is RUNNING, but could not be verified (see above). Check it with scripts/verify-pod.sh; nothing else is tried." >&2
            exit 1
            ;;
          3) echo "[$(date +%H:%M:%S)] round $attempt: the name '$newname' was taken meanwhile; picking another next round" ;;
          *)
            printf '%s\n' "$OUT" >&2
            if printf '%s' "$OUT" | grep -q "^Created Pod "; then
              echo "A Pod '$newname' WAS created but did not pass verification (see above for what was done with it). Nothing else is tried." >&2
            elif printf '%s' "$OUT" | grep -q "response had no Pod id"; then
              echo "A Pod may have been created for '$newname' (the response had no id) and may be billing: check scripts/v2-smoke.sh. Nothing else is tried." >&2
            else
              echo "Creating '$newname' failed (exit $RC); stopping." >&2
            fi
            exit 1
            ;;
        esac
      elif [ "$(pool_count)" -ge "$POOL_MAX" ] && [ "$full_noted" -eq 0 ]; then
        echo "The pool is full ($POOL_MAX Pods): no new Pod is created; only restarting is tried. Terminate an unused one (scripts/pod-terminate.sh) to make room."
        full_noted=1
      fi
    fi
  fi

  remaining=$((MAX_WAIT - (SECONDS - start)))
  [ "$remaining" -gt 0 ] || continue   # the loop head gives up
  nap="$INTERVAL"; [ "$remaining" -ge "$nap" ] || nap="$remaining"
  sleep "$nap" 8>&- 9>&-   # fd 8/9: never hold the lock through a sleep, so a kill frees it at once
done
