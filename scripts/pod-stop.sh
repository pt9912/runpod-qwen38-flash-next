#!/usr/bin/env bash
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
: "${RUNPOD_POD_ID:?Set RUNPOD_POD_ID}"
case "$RUNPOD_POD_ID" in *[!a-z0-9]*) echo "Invalid Pod ID '$RUNPOD_POD_ID' (expected lower-case letters and digits)" >&2; exit 2 ;; esac
# shellcheck source=scripts/_api.sh
source "$(dirname "$0")/_api.sh"

# Show which Pod this acts on (a stale RUNPOD_POD_ID would stop the wrong one).
set +e
info="$(api_pod_info "$RUNPOD_POD_ID" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$info" >&2
  echo >&2
  api_auth_hint "$info" && exit 1
  case "$(printf '%s' "$info" | head -n1)" in
    "HTTP 404"*) echo "Pod $RUNPOD_POD_ID does not exist. Check RUNPOD_POD_ID." >&2 ;;
    *) echo "Could not read Pod $RUNPOD_POD_ID; nothing was stopped." >&2 ;;
  esac
  exit 1
fi
IFS=$'\t' read -r name status cost dc <<<"$info"
echo "Target: $name ($RUNPOD_POD_ID), status $status, \$$cost/h, datacenter $dc"
status_uc="$(printf '%s' "$status" | tr '[:lower:]' '[:upper:]')"
if [ "$status_uc" = "EXITED" ]; then
  echo "Already stopped; nothing to do."
  exit 0
fi

# Stopping releases the GPU (billing stops) but keeps the Pod tied to its machine:
# another user may rent the GPU meanwhile, see README.md "If the GPU is occupied".
set +e
out="$(api_post "/pods/$RUNPOD_POD_ID/action" '{"action":"stop"}' 2>&1)"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" >&2
  echo >&2
  api_auth_hint "$out" && exit 1
  case "$(printf '%s' "$out" | head -n1)" in
    "HTTP "*) echo "pod stop failed for Pod $RUNPOD_POD_ID (see the message above)." >&2 ;;
    *) echo "The connection failed while the stop request may already have been sent: the outcome is UNKNOWN. Check the status before retrying: scripts/v2-smoke.sh" >&2 ;;
  esac
  exit 1
fi

printf '%s' "$out" | api_print_pod
