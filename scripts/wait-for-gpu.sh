#!/usr/bin/env bash
# Polls GPU stock (read-only) until the GPU is available, then reports and exits 0.
# It NEVER starts or creates anything: starting bills the GPU, that stays your call.
# Stock is an ordering hint, not a reservation; act quickly and expect a start
# can still fail.
#
# Usage: wait-for-gpu.sh [GPU_MATCH] [DATACENTER_ID] [INTERVAL_SECONDS] [TIMEOUT_SECONDS]
#   defaults: B200, the datacenter of the Pod RUNPOD_POD_ID (overall stock if that is not set or
#             cannot be read), 60 s, 0 (= wait until Ctrl-C). DATACENTER_ID "any" = overall stock.
# Example: wait-for-gpu.sh B200            (datacenter taken from RUNPOD_POD_ID)
#          wait-for-gpu.sh B200 EU-NL-1    (explicit datacenter)
#
# Exit codes: 0 = in stock, 3 = timeout, 4 = unknown GPU type or datacenter (typo),
# 1 = the API kept failing for 5 minutes (WAIT_MAX_ERROR_SECONDS) or the key was rejected (401/403),
# 2 = bad arguments.
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"

MATCH="${1:-B200}"
DC="${2:-}"
INTERVAL="${3:-60}"
TIMEOUT="${4:-0}"
MAX_ERR="${WAIT_MAX_ERROR_SECONDS:-300}"
case "$INTERVAL$TIMEOUT$MAX_ERR" in *[!0-9]*) echo "INTERVAL, TIMEOUT and WAIT_MAX_ERROR_SECONDS must be whole seconds" >&2; exit 2 ;; esac
[ "${#INTERVAL}" -le 9 ] && [ "${#TIMEOUT}" -le 9 ] && [ "${#MAX_ERR}" -le 9 ] || { echo "numeric values must have at most 9 digits" >&2; exit 2; }
[ "$((10#$INTERVAL))" -ge "${WAIT_MIN_INTERVAL:-10}" ] || { echo "INTERVAL must be >= 10 s (API rate limit)" >&2; exit 2; }

INTERVAL=$((10#$INTERVAL)); TIMEOUT=$((10#$TIMEOUT)); MAX_ERR=$((10#$MAX_ERR))   # "08" is decimal, not invalid octal
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"   # for api_auth_hint

# Resolve the datacenter once (not on every poll): explicit, "any", or the Pod's own one.
dc_lc="$(printf '%s' "$DC" | tr '[:upper:]' '[:lower:]')"
if [ "$dc_lc" = "any" ]; then
  DC=""
elif [ -z "$DC" ] && [ -n "${RUNPOD_POD_ID:-}" ]; then
  pod_dc="$(api_pod_datacenter "$RUNPOD_POD_ID")"
  if [ "$pod_dc" != "?" ]; then
    DC="$pod_dc"
    echo "Datacenter: $DC (of Pod $RUNPOD_POD_ID; pass 'any' as the datacenter for the overall stock)"
  else
    echo "Note: could not read the datacenter of Pod $RUNPOD_POD_ID; watching the overall stock." >&2
  fi
fi

start=$SECONDS
first_error=""
where=" (overall stock, any datacenter)"; [ -z "$DC" ] || where=" in $DC"
echo "Waiting for ${MATCH}${where} (every ${INTERVAL}s, timeout: $([ "$TIMEOUT" -gt 0 ] && echo "${TIMEOUT}s" || echo none)). Read-only, Ctrl-C to stop."

while true; do
  set +e
  out="$("$HERE/gpu-availability.sh" "$MATCH" "${DC:-any}" 2>&1)"
  rc=$?
  set -e
  now="$(date +%H:%M:%S)"

  case "$rc" in
    0)
      printf '\a'
      echo "[$now] IN STOCK:"
      printf '%s\n' "$out"
      echo "Next: scripts/pod-start.sh (restart the stopped Pod) or scripts/create-pod.sh --yes (dry run without --yes)."
      exit 0
      ;;
    2)
      first_error=""
      echo "[$now] no stock"
      ;;
    4)
      # Not "no stock": a typo would otherwise be polled forever.
      printf '%s\n' "$out" >&2
      exit 4
      ;;
    *)
      # A rejected or unauthorised key will not fix itself: stop at once.
      case "$(printf '%s' "$out" | head -n1)" in
        "HTTP 401"*|"HTTP 403"*)
          printf '%s\n' "$out" >&2
          api_auth_hint "$out" || true
          exit 1
          ;;
      esac
      [ -n "$first_error" ] || first_error=$SECONDS
      echo "[$now] API error: $(printf '%s' "$out" | head -n1)" >&2
      if [ $((SECONDS - first_error)) -ge "$MAX_ERR" ]; then
        echo "The API kept failing for ${MAX_ERR}s; giving up." >&2
        exit 1
      fi
      ;;
  esac

  nap="$INTERVAL"
  if [ "$TIMEOUT" -gt 0 ]; then
    remaining=$((TIMEOUT - (SECONDS - start)))
    if [ "$remaining" -le 0 ]; then
      echo "Timeout after ${TIMEOUT}s without stock." >&2
      exit 3
    fi
    [ "$remaining" -ge "$nap" ] || nap="$remaining"
  fi
  sleep "$nap"
done
