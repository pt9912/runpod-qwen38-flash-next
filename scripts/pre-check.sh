#!/usr/bin/env bash
# Pre-flight check: are the required tools installed and the local setup complete?
# Read-only; never starts or changes anything. Secrets are never printed.
#
# Usage: pre-check.sh [--online]
#   --online  additionally do one read-only GET /pods to verify the API key
#
# Exit code: 0 = no blocking problem (warnings are allowed), 1 = at least one FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ONLINE=0
case "${1:-}" in
  "") ;;
  --online) ONLINE=1 ;;
  *) echo "usage: pre-check.sh [--online]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: pre-check.sh [--online]" >&2; exit 2; }

fails=0
warns=0
ok()   { printf '[ ok ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; fails=$((fails + 1)); }

echo "== Tools =="
# curl and python3 are used by every script (API calls, JSON handling).
for t in curl python3; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t: $(command -v "$t")"
  else
    fail "$t is not installed (required by all scripts). Install it with your package manager (apt, dnf, brew, ...)"
  fi
done

echo
echo "== Environment (values are never printed) =="
if [ -n "${RUNPOD_API_KEY:-}" ]; then
  ok "RUNPOD_API_KEY is set"
else
  fail "RUNPOD_API_KEY is empty or not exported (use: set -a; source .env; set +a)"
fi
if [ -n "${RUNPOD_POD_ID:-}" ]; then
  ok "RUNPOD_POD_ID is set"
else
  warn "RUNPOD_POD_ID is not set (needed by pod-start.sh, pod-stop.sh, verify-pod.sh, wait-for-ready.sh for a single Pod; start-any.sh / stop-any.sh do not need it)"
fi
if [ -n "${VLLM_API_KEY:-}" ]; then
  ok "VLLM_API_KEY is set"
else
  warn "VLLM_API_KEY is not set (needed by wait-for-ready.sh, check-endpoint.sh and clients such as Claude Code)"
fi

echo
echo "== Configuration =="
if [ -n "${NETWORK_VOLUME_ID:-}" ]; then
  ok "NETWORK_VOLUME_ID is set"
else
  warn "NETWORK_VOLUME_ID is not set (needed by create-pod.sh and start-any.sh to create Pods; put it in .env)"
fi

if [ "$ONLINE" -eq 1 ]; then
  echo
  echo "== API (read-only GET /pods) =="
  if [ -z "${RUNPOD_API_KEY:-}" ]; then
    fail "skipped: RUNPOD_API_KEY is not set"
  elif ! command -v curl >/dev/null 2>&1; then
    fail "skipped: curl is not installed"
  else
    # shellcheck source=scripts/_api.sh
    source "$ROOT/scripts/_api.sh"
    # api_get keeps no temp files; its error text goes to stderr and is captured here.
    if err="$(api_get /pods 2>&1 >/dev/null)"; then
      ok "API reachable and key accepted (${BASE})"
    else
      fail "API check failed: $(printf '%s' "$err" | head -n1)"
    fi
  fi
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "Result: $fails blocking problem(s), $warns warning(s)."
  exit 1
fi
echo "Result: ready ($warns warning(s))."
