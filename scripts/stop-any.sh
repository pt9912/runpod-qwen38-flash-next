#!/usr/bin/env bash
# Stops every active Pod of the pool (any status except EXITED/ERROR/TERMINATED) (name starts with POOL_PREFIX, default
# qwen3.8-flash-next). Stopping ends the GPU billing. Use this instead of pod-stop.sh when the
# running Pod's ID changes (pool). Nothing to do if no pool Pod is running.
#
# Usage: stop-any.sh [--dry-run]
# Environment: STOP_LIST_TRIES (default 5) and STOP_RETRY_DELAY (default 5 s): how often / how long apart the
#   Pod list is read before giving up (reading is safe to repeat).
# Exit codes: 0 = done (or nothing to stop), 1 = at least one stop failed, 2 = bad arguments.
set -uo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"
# shellcheck source=scripts/_pool.sh
source "$HERE/_pool.sh"

DRY=0
for a in "$@"; do
  case "$a" in --dry-run) DRY=1 ;; *) echo "unknown argument: $a" >&2; exit 2 ;; esac
done
# Reading the list is safe to repeat: a single network hiccup must not leave a billing Pod running.
tries="${STOP_LIST_TRIES:-5}"; delay="${STOP_RETRY_DELAY:-5}"; n=0
until pool_refresh; do
  n=$((n + 1))
  printf '%s\n' "$POOL_ERR" >&2
  if [ "$n" -ge "$tries" ]; then echo "Could not list Pods $tries times; NOTHING WAS STOPPED. A Pod may still be billing: check scripts/v2-smoke.sh." >&2; exit 1; fi
  echo "Could not list Pods (try $n of $tries); retrying in ${delay}s ..." >&2
  sleep "$delay"
done

fail=0; found=0
while IFS=$'\t' read -r id name status; do
  [ -n "$id" ] || continue
  pool_status_active "$status" || continue   # everything except EXITED/ERROR/TERMINATED counts as running
  found=1
  if [ "$DRY" -eq 1 ]; then echo "DRY RUN: would stop '$name' ($id), status $status"; continue; fi
  RUNPOD_POD_ID="$id" "$HERE/pod-stop.sh" || fail=1
done <<<"$POOL_MEMBERS"
[ "$found" -eq 1 ] || echo "No running '$POOL_PREFIX*' Pod; nothing to stop."
exit "$fail"
