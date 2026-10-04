#!/usr/bin/env bash
# Starts the stopped Pod RUNPOD_POD_ID (this bills the GPU from the moment it runs).
# Usage: pod-start.sh [--force]        (POD_START_FORCE=1 does the same)
# A Pod of the pool (name starts with POOL_PREFIX) is NOT started while another pool Pod is active:
# two pool Pods must not run at once (they share /workspace/vllm-cache and would bill twice). For
# that check it takes the same lock as start-any.sh/create-pod.sh (skipped if a caller already
# holds it, POOL_LOCK_HELD=1), so a standalone run cannot race a pool run started elsewhere on this
# machine. --force skips both the check and the lock.
# Exit codes: 0 = started or already running, 1 = failure (auth, or the connection broke so the
# outcome is UNKNOWN), 2 = bad arguments, 4 = another start/create is in progress on this machine
# (nothing sent), 5 = the GPU on the Pod's machine is occupied (nothing started, nothing billed;
# safe to retry, see scripts/start-when-free.sh), 6 = the Pod or the pool could not be read
# (timeout, 5xx, 429...): nothing was sent, safe to retry, 8 = the request was definitively
# rejected (unknown Pod, wrong status, or a 4xx other than "occupied"): nothing was sent or
# changed, safe to try a different Pod, 9 = refused: another pool Pod is active (nothing sent).
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
: "${RUNPOD_POD_ID:?Set RUNPOD_POD_ID}"
case "$RUNPOD_POD_ID" in *[!a-z0-9]*) echo "Invalid Pod ID '$RUNPOD_POD_ID' (expected lower-case letters and digits)" >&2; exit 2 ;; esac
# shellcheck source=scripts/_api.sh
source "$(dirname "$0")/_api.sh"
# shellcheck source=scripts/_pool.sh
source "$(dirname "$0")/_pool.sh"

FORCE="${POD_START_FORCE:-0}"
for a in "$@"; do
  case "$a" in --force) FORCE=1 ;; *) echo "unknown argument: $a (usage: pod-start.sh [--force])" >&2; exit 2 ;; esac
done

# 1. Show which Pod this acts on (a stale RUNPOD_POD_ID would start the wrong one).
set +e
info="$(api_pod_info "$RUNPOD_POD_ID" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$info" >&2
  echo >&2
  api_auth_hint "$info" && exit 1
  case "$(printf '%s' "$info" | head -n1)" in
    "HTTP 404"*)
      echo "Pod $RUNPOD_POD_ID does not exist. Check RUNPOD_POD_ID (a redeploy changes the Pod ID; list the Pods with scripts/v2-smoke.sh)." >&2
      exit 8
      ;;
    *)
      echo "Could not read Pod $RUNPOD_POD_ID (possibly a temporary problem); nothing was started." >&2
      exit 6
      ;;
  esac
fi
IFS=$'\t' read -r name status cost dc <<<"$info"
echo "Target: $name ($RUNPOD_POD_ID), status $status, \$$cost/h, datacenter $dc"
# The Pod's datacenter is the one that matters for stock (the volume is bound to it).
dc_hint="<DATACENTER OF YOUR VOLUME>"
[ "$dc" = "?" ] || dc_hint="$dc"
status_uc="$(printf '%s' "$status" | tr '[:lower:]' '[:upper:]')"
case "$status_uc" in
  RUNNING|STARTING|PROVISIONING)
    echo "Already $status; nothing to do."
    exit 0
    ;;
esac

# 1b. Never a second pool Pod: refuse if another Pod of the pool is active (reading the pool is safe to repeat).
case "$name" in
  "$POOL_PREFIX"*)
    if [ "$FORCE" != 1 ]; then
      # Same lock as start-any.sh/create-pod.sh, so this check-then-act cannot race one of them
      # starting or creating a Pod elsewhere on this machine. Skipped if a caller already holds it.
      if [ "${POOL_LOCK_HELD:-0}" != 1 ]; then
        pool_lock_acquire || { echo "Another start-any.sh / create-pod.sh is in progress on this machine (PID ${POOL_LOCK_HOLDER:-?}, lock $POOL_LOCKFILE). Nothing was started." >&2; exit 4; }
        trap 'pool_lock_release' EXIT
      fi
      n=0
      until pool_refresh; do
        n=$((n + 1))
        if [ "$n" -ge 3 ]; then
          printf '%s\n' "$POOL_ERR" >&2
          echo "Could not check whether another pool Pod is active; nothing was started (safe to retry, or use --force)." >&2
          exit 6
        fi
        sleep 2
      done
      if other="$(pool_other_active "$RUNPOD_POD_ID")"; then
        IFS=$'\t' read -r o_id o_name o_status <<<"$other"
        echo "Refusing to start: the pool Pod '$o_name' ($o_id) is already $o_status. Two pool Pods must not run at once." >&2
        echo "Stop it first (scripts/stop-any.sh), or use --force if you really want both." >&2
        exit 9
      fi
    fi
    ;;
esac

# 2. Start. This bills the GPU from the moment it runs.
# A stopped Pod resumes on its original machine. If another user rented that GPU
# meanwhile, the API answers (observed 2026-09-24):
#   HTTP 400 {"detail":"There are not enough free GPUs on the host machine to start this pod."}
# Only that case gets the redeploy advice. 404 = unknown Pod, 409 = the current
# status does not allow "start", 401/403 = API key problems.
set +e
out="$(api_post "/pods/$RUNPOD_POD_ID/action" '{"action":"start"}' 2>&1)"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" >&2
  echo >&2
  api_auth_hint "$out" && exit 1
  first="$(printf '%s' "$out" | head -n1)"
  occupied=0; rejected=0
  case "$first" in
    "HTTP 400"*)
      if printf '%s' "$out" | grep -q "not enough free GPUs"; then
        occupied=1
        cat >&2 <<HINT
The GPU on this Pod's machine is occupied by someone else (nothing was started, nothing is billed).
Options: wait and retry, or redeploy with the same volume; see README.md "If the GPU is occupied":
  - be notified when the GPU is free there: make wait-gpu ARGS='"${GPU_ID:-B200}" $dc_hint'
  - redeploy with the same volume: make create (dry run first, then ARGS=--yes)
A redeploy changes the Pod ID; update RUNPOD_POD_ID and QWEN_URL afterwards.
HINT
      else
        echo "The API rejected the request (see the message above); nothing was started." >&2
        rejected=1
      fi
      ;;
    "HTTP 404"*) echo "Pod $RUNPOD_POD_ID does not exist. Check RUNPOD_POD_ID." >&2; rejected=1 ;;
    "HTTP 409"*) echo "The Pod's current status ($status) does not allow 'start' (it may already be running)." >&2; rejected=1 ;;
    "HTTP "*) echo "pod start failed for Pod $RUNPOD_POD_ID (see the message above)." >&2 ;;
    *) echo "The connection failed while the start request may already have been sent: the outcome is UNKNOWN and the Pod may be starting (and billing). Check before retrying: scripts/v2-smoke.sh" >&2 ;;
  esac
  [ "$occupied" -eq 0 ] || exit 5
  [ "$rejected" -eq 0 ] || exit 8
  exit 1
fi

printf '%s' "$out" | api_print_pod
