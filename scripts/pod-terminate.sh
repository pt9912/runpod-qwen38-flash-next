#!/usr/bin/env bash
# Permanently deletes a Pod (POST /v2/pods/{id}/action terminate). This cannot be undone.
# The Network Volume is NOT deleted (it is a separate resource), so model and caches survive.
# Requires --yes; without it only the target is shown.
#
# Usage: pod-terminate.sh --yes [POD_ID]      (POD_ID defaults to RUNPOD_POD_ID)
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"

YES=0; POD_ID=""
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;;
    -*) echo "unknown argument: $a" >&2; exit 2 ;;
    *) POD_ID="$a" ;;
  esac
done
POD_ID="${POD_ID:-${RUNPOD_POD_ID:-}}"
[ -n "$POD_ID" ] || { echo "Give a POD_ID or set RUNPOD_POD_ID" >&2; exit 2; }
case "$POD_ID" in *[!a-z0-9]*) echo "Invalid Pod ID '$POD_ID' (expected lower-case letters and digits)" >&2; exit 2 ;; esac

set +e
info="$(api_pod_info "$POD_ID" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$info" >&2
  api_auth_hint "$info" && exit 1
  echo "Could not read Pod $POD_ID; nothing was terminated." >&2
  exit 1
fi
IFS=$'\t' read -r name status cost dc <<<"$info"
echo "Target: $name ($POD_ID), status $status, \$$cost/h, datacenter $dc"
if [ "$(printf '%s' "$status" | tr '[:lower:]' '[:upper:]')" = "TERMINATED" ]; then
  echo "Already terminated; nothing to do."
  exit 0
fi
if [ "$YES" -ne 1 ]; then
  echo "This would permanently delete the Pod (the Network Volume stays). Add --yes to do it."
  exit 0
fi

set +e
out="$(api_post "/pods/$POD_ID/action" '{"action":"terminate"}' 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" >&2
  echo >&2
  api_auth_hint "$out" && exit 1
  case "$(printf '%s' "$out" | head -n1)" in
    "HTTP "*) echo "terminate failed for Pod $POD_ID (see above)." >&2 ;;
    *) echo "The connection failed; the outcome is UNKNOWN. Check with scripts/v2-smoke.sh before retrying." >&2 ;;
  esac
  exit 1
fi
echo "Pod $POD_ID terminated."
