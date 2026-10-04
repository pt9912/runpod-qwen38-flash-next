#!/usr/bin/env bash
# Starts the stopped Pod RUNPOD_POD_ID, retrying while its GPU is occupied.
# Why retry the start instead of polling the catalog stock: a stopped Pod resumes on its
# OWN machine, and the catalog stock says nothing about that machine. A failed start
# ("not enough free GPUs", pod-start.sh exit 5) costs nothing, so trying is cheap.
#
# Retried: exit 5 (GPU occupied) and exit 6 (Pod could not be read; nothing was sent; at most
# 10 in a row). Any other failure (auth, unknown Pod, an UNKNOWN outcome after a broken
# connection) stops at once, so a possibly started Pod is never started twice.
# One successful start ends the script; it never starts more than once.
# THE START BILLS THE GPU from the moment it succeeds.
#
# MAX_WAIT_SECONDS limits when attempts BEGIN: no attempt starts once it has elapsed. An
# attempt already running can take up to about 2 more minutes (API timeouts), so a start can
# still succeed slightly after the cap.
#
# Usage: start-when-free.sh [MAX_WAIT_SECONDS] [INTERVAL_SECONDS]     defaults: 7200, 60
# Exit codes: 0 = started (or already running), 3 = gave up (GPU stayed occupied),
#             130 = interrupted (see the message: a start request may already have been sent),
#             2 = bad arguments, 1 or other = pod-start.sh failed for another reason (message shown).
set -uo pipefail

MAX_WAIT="${1:-7200}"
INTERVAL="${2:-60}"
case "$MAX_WAIT$INTERVAL" in *[!0-9]*) echo "MAX_WAIT_SECONDS and INTERVAL_SECONDS must be whole seconds" >&2; exit 2 ;; esac
[ "${#MAX_WAIT}" -le 9 ] && [ "${#INTERVAL}" -le 9 ] || { echo "MAX_WAIT_SECONDS and INTERVAL_SECONDS must have at most 9 digits" >&2; exit 2; }
MAX_WAIT=$((10#$MAX_WAIT)); INTERVAL=$((10#$INTERVAL))
[ "$INTERVAL" -ge "${START_MIN_INTERVAL:-30}" ] || { echo "INTERVAL must be >= 30 s (API rate limit)" >&2; exit 2; }
: "${RUNPOD_POD_ID:?Set RUNPOD_POD_ID}"

HERE="$(dirname "$0")"
tmp="$(mktemp)"
child=""
trap 'rm -f "$tmp"' EXIT
on_signal() {
  # Job cancelled or timed out. Stop the running attempt (this prevents a start that has not
  # been sent yet) but say clearly that one that was already sent cannot be undone.
  [ -z "$child" ] || kill -TERM -- "-$child" 2>/dev/null
  echo >&2
  echo "Interrupted. If a start request had already been sent, the Pod may be starting (and billing): check with scripts/v2-smoke.sh." >&2
  exit 130
}
trap on_signal INT TERM

start=$SECONDS
attempt=0
read_failures=0
echo "Trying to start Pod $RUNPOD_POD_ID (attempts begin for up to ${MAX_WAIT}s, every ${INTERVAL}s)."

while true; do
  if [ "$attempt" -gt 0 ] && [ $((SECONDS - start)) -ge "$MAX_WAIT" ]; then
    echo "Gave up after ${MAX_WAIT}s and $attempt attempt(s): the Pod could not be started. Nothing was started." >&2
    exit 3
  fi
  attempt=$((attempt + 1))

  # Own process group (set -m) so an interrupt can stop pod-start.sh and its curl together.
  set -m
  "$HERE/pod-start.sh" >"$tmp" 2>&1 &
  child=$!
  set +m
  wait "$child"
  rc=$?
  child=""
  out="$(cat "$tmp")"

  case "$rc" in
    0)
      printf '%s\n' "$out"
      echo "Started after $attempt attempt(s), $((SECONDS - start))s."
      exit 0
      ;;
    5|6)
      if [ "$rc" -eq 6 ]; then
        read_failures=$((read_failures + 1))
        if [ "$read_failures" -ge 10 ]; then
          printf '%s\n' "$out" >&2
          echo "The Pod could not be read 10 times in a row; giving up. Nothing was started." >&2
          exit 1
        fi
        echo "[$(date +%H:%M:%S)] attempt $attempt: could not read the Pod (temporary?), nothing sent"
      else
        read_failures=0
        # Show the full message once; afterwards one short line per attempt.
        [ "$attempt" -ne 1 ] || printf '%s\n' "$out"
        echo "[$(date +%H:%M:%S)] attempt $attempt: GPU on the Pod's machine still occupied"
      fi
      ;;
    *)
      printf '%s\n' "$out" >&2
      exit "$rc"
      ;;
  esac

  remaining=$((MAX_WAIT - (SECONDS - start)))
  [ "$remaining" -gt 0 ] || continue   # the loop head gives up
  nap="$INTERVAL"
  [ "$remaining" -ge "$nap" ] || nap="$remaining"
  sleep "$nap"
done
