#!/usr/bin/env bash
# Measures how long a Pod takes from "started" to "vLLM answers": polls
# GET <Pod URL>/v1/models with the vLLM API key until it returns 200, prints the
# elapsed time and appends it to .startup-times.log (git-ignored).
# It only reads; it never starts or stops anything. Typical use:
#   scripts/start-when-free.sh 1200 30 && scripts/wait-for-ready.sh
#
# Usage: wait-for-ready.sh [TIMEOUT_SECONDS] [INTERVAL_SECONDS]      defaults: 3600, 15
# Which Pod: the single ACTIVE pool Pod (needs RUNPOD_API_KEY), else RUNPOD_POD_ID, else QWEN_URL
#        (https://<id>-8000.proxy.runpod.net for a Pod ID); the choice and the reason are printed.
#        Needs VLLM_API_KEY (required).
# Exit codes: 0 = ready, 3 = timeout, 4 = key rejected (HTTP 401/403), 2 = bad arguments/setup,
# 1 = VLLM_API_KEY not set (also 2 if several pool Pods are active and none was chosen).
#
# The clock starts at the Pod's `startedAt` from the API (needs RUNPOD_API_KEY and a Pod ID:
# the one in the proxy URL, or RUNPOD_POD_ID), so the result does not depend on when this
# script was launched. The API did update startedAt on a restart when this was measured
# (2026-09-26); your local clock must be accurate. Without that, the clock starts when this script starts (then run it
# together with the Pod). The resolution is the polling interval (default 15 s).
# If the Pod already answers on the first poll, nothing is logged (it was already running).
# Every answer except 200 and 401/403 counts as "not ready yet" (e.g. 502/524 from the
# RunPod proxy while the container boots, 404, 500, connection errors).
set -euo pipefail
: "${VLLM_API_KEY:?Set VLLM_API_KEY (the value of your RunPod Secret)}"

TIMEOUT="${1:-3600}"
INTERVAL="${2:-15}"
case "$TIMEOUT$INTERVAL" in *[!0-9]*) echo "TIMEOUT and INTERVAL must be whole seconds" >&2; exit 2 ;; esac
[ "${#TIMEOUT}" -le 9 ] && [ "${#INTERVAL}" -le 9 ] || { echo "TIMEOUT and INTERVAL must have at most 9 digits" >&2; exit 2; }
TIMEOUT=$((10#$TIMEOUT)); INTERVAL=$((10#$INTERVAL))   # "08" is decimal, not invalid octal
[ "$INTERVAL" -ge "${READY_MIN_INTERVAL:-5}" ] || { echo "INTERVAL must be >= 5 s" >&2; exit 2; }

HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"
# shellcheck source=scripts/_pool.sh
source "$HERE/_pool.sh"
LOG="$(cd "$HERE/.." && pwd)/.startup-times.log"

# Which Pod: the single ACTIVE pool Pod (needs RUNPOD_API_KEY), else RUNPOD_POD_ID, else QWEN_URL. A stale
# RUNPOD_POD_ID or QWEN_URL left in .env must not send the measurement to a stopped Pod.
resolve_rc=0; pool_resolve_pod "" || resolve_rc=$?
case "$resolve_rc" in
  0)
    URL="https://${RESOLVED_POD_ID}-8000.proxy.runpod.net"
    echo "Pod: $RESOLVED_POD_ID (source: $RESOLVED_SOURCE)"
    ;;
  2)
    echo "Several pool Pods are active; run it with RUNPOD_POD_ID set to the one you mean. Active pool Pods:" >&2
    printf '%s' "$POOL_MEMBERS" | while IFS=$'\t' read -r i n st; do [ -z "$i" ] || printf '  %s  %s  %s\n' "$n" "$i" "$st" >&2; done
    exit 2
    ;;
  *)
    if [ -n "${QWEN_URL:-}" ]; then
      URL="${QWEN_URL%/}"
      URL="${URL%/v1}"   # the script appends /v1/models itself
      echo "Pod: from QWEN_URL"
    else
      echo "No pool Pod is active and neither RUNPOD_POD_ID nor QWEN_URL is set" >&2
      exit 2
    fi
    ;;
esac

# Which Pod is measured: the one in a proxy URL (https://<id>-8000.proxy.runpod.net).
POD_ID=""
case "$URL" in
  https://*-8000.proxy.runpod.net) POD_ID="${URL#https://}"; POD_ID="${POD_ID%-8000.proxy.runpod.net}" ;;
esac
POD_LABEL="${POD_ID:-url}"

# Clock start: the Pod's startedAt from the API if possible, else the start of this script.
origin="script"; origin_epoch=""; origin_note="no Pod ID in the URL"
if [ -n "$POD_ID" ]; then
  origin_note="RUNPOD_API_KEY is not set"
  if [ -n "${RUNPOD_API_KEY:-}" ]; then
    # shellcheck source=scripts/_api.sh
    source "$HERE/_api.sh"
    set +e
    info="$(api_get "/pods/$POD_ID" 2>/dev/null)"
    rc=$?
    set -e
    origin_note="the API did not return a usable startedAt"
    if [ "$rc" -eq 0 ]; then
      origin_epoch="$(printf '%s' "$info" | python3 -c '
import json, sys, datetime
try:
    s = json.load(sys.stdin).get("startedAt")
    if s:
        dt = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:   # no offset: the API means UTC, do not read it as local time
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        print(int(dt.timestamp()))
    else:
        print("")
except Exception:
    print("")')"
    fi
    if [ -n "$origin_epoch" ]; then
      age=$(( $(date +%s) - origin_epoch ))
      # Plausible only if recent: a startedAt of a previous run (the API not updated yet) or a skewed
      # clock must not become a startup time.
      limit=$(( TIMEOUT * 2 > 7200 ? TIMEOUT * 2 : 7200 ))
      if [ "$age" -ge 0 ] && [ "$age" -lt "$limit" ]; then
        origin="startedAt"
      else
        origin_epoch=""; origin_note="startedAt is in the future or older than ${limit} s (the API may not have updated it yet, or your clock is off)"
      fi
    fi
  fi
fi
start=$SECONDS
polls=0
echo "Waiting for ${URL}/v1/models (every ${INTERVAL}s, timeout ${TIMEOUT}s). Read-only, Ctrl-C to stop."
if [ "$origin" = "startedAt" ]; then
  echo "Clock start: the Pod's startedAt ($(date -u -d "@$origin_epoch" +%Y-%m-%dT%H:%M:%SZ), $age s ago)."
else
  echo "Clock start: the start of this script (${origin_note}); run it together with the Pod for a meaningful time."
fi

while true; do
  set +e
  # The key goes through stdin (--config -) so it never appears in `ps`.
  code="$(curl -sS -o /dev/null --connect-timeout 10 -m 20 -w '%{http_code}' --config - "${URL}/v1/models" 2>/dev/null <<EOT
header = "Authorization: Bearer ${VLLM_API_KEY}"
EOT
  )"
  set -e
  code="${code:-000}"
  waited=$((SECONDS - start))          # for the timeout: always time since this script started
  if [ "$origin" = "startedAt" ]; then elapsed=$(( $(date +%s) - origin_epoch )); else elapsed=$waited; fi
  polls=$((polls + 1))

  case "$code" in
    200)
      printf '\a'
      if [ "$polls" -eq 1 ]; then
        # Answered on the very first poll: the Pod was already up, so this is not a startup time.
        echo "READY on the first poll: the Pod was already running. No startup time recorded."
        exit 0
      fi
      printf 'READY after %dm %02ds (%ds), measured from %s\n' $((elapsed / 60)) $((elapsed % 60)) "$elapsed" "$([ "$origin" = startedAt ] && echo "the Pod's startedAt" || echo "the start of this script")"
      printf '%s pod=%s seconds=%d source=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$POD_LABEL" "$elapsed" "$origin" >>"$LOG"
      echo "Logged to $LOG"
      exit 0
      ;;
    401|403)
      echo "HTTP $code: the server rejects VLLM_API_KEY. Check that it equals the RunPod Secret VLLM_API_KEY." >&2
      exit 4
      ;;
    *)
      printf '[%s] %dm %02ds: not ready (HTTP %s)\n' "$(date +%H:%M:%S)" $((elapsed / 60)) $((elapsed % 60)) "$code"
      ;;
  esac

  remaining=$((TIMEOUT - waited))
  if [ "$remaining" -le 0 ]; then
    echo "Timeout after ${TIMEOUT}s: vLLM did not answer 200." >&2
    exit 3
  fi
  nap="$INTERVAL"
  [ "$remaining" -ge "$nap" ] || nap="$remaining"
  sleep "$nap"
done
