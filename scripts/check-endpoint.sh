#!/usr/bin/env bash
# Read-only check of a running Pod through the RunPod HTTPS proxy (no SSH needed):
#   1. WITHOUT a key the /v1 API must answer 401 (if it answers 200, the server is OPEN to everyone),
#   2. WITH your key it must answer 200 (a 401 means the server runs with a different key, for
#      example an unresolved RunPod Secret placeholder after a mistyped secret name),
#   3. the served model is qwen3.8-flash-next with the configured context (MAX_MODEL_LEN, default 131072).
# Prints only statuses, the model id and the context length, never a key.
#
# Usage: check-endpoint.sh [POD_ID]
#   Which Pod: POD_ID if given; else the single ACTIVE pool Pod (needs RUNPOD_API_KEY); else
#   RUNPOD_POD_ID; else QWEN_URL. The chosen Pod and the reason are printed. If several pool Pods are
#   active, give the POD_ID. A Pod ID must be lower-case letters and digits.
#   Needs VLLM_API_KEY (the value of your RunPod Secret).
# Notes: vLLM protects only /v1/*; /health, /metrics and /docs are open by design, so they are not used
#   for the negative test and "protected" here means the /v1 API.
# Exit codes: 0 = all checks passed, 1 = at least one FAIL, 2 = bad arguments/setup (including a
#   missing VLLM_API_KEY), 3 = the endpoint does not answer (Pod still booting, or the proxy/server gave
#   502/503/504/524/429/5xx/404 or no answer): nothing could be concluded.
set -uo pipefail
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"
# shellcheck source=scripts/_pool.sh
source "$HERE/_pool.sh"

[ -n "${VLLM_API_KEY:-}" ] || { echo "Set VLLM_API_KEY (the value of your RunPod Secret)" >&2; exit 2; }

pool_resolve_pod "${1:-}"; rc=$?
case "$rc" in
  0) POD_ID="$RESOLVED_POD_ID"; SOURCE="$RESOLVED_SOURCE" ;;
  2) echo "Several pool Pods are active; give the POD_ID:" >&2
     printf '%s' "$POOL_MEMBERS" | while IFS=$'\t' read -r i n st; do [ -z "$i" ] || printf '  %s  %s  %s\n' "$n" "$i" "$st" >&2; done
     exit 2 ;;
  *) POD_ID=""; SOURCE="" ;;
esac
if [ -n "$POD_ID" ]; then
  case "$POD_ID" in *[!a-z0-9]*) echo "Invalid Pod ID '$POD_ID' (expected lower-case letters and digits)" >&2; exit 2 ;; esac
  URL="https://${POD_ID}-8000.proxy.runpod.net"
elif [ -n "${QWEN_URL:-}" ]; then
  URL="${QWEN_URL%/}"; URL="${URL%/v1}"; SOURCE="QWEN_URL"
else
  echo "Give a POD_ID, or start a pool Pod, or set RUNPOD_POD_ID or QWEN_URL" >&2; exit 2
fi

fails=0
ok()   { printf '[ ok ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; fails=$((fails + 1)); }
not_answering() { echo "[....] the endpoint does not answer (HTTP $1): the Pod may still be booting, or it is stopped. Try scripts/wait-for-ready.sh."; exit 3; }

# get PATH [withkey]: sets CODE and BODY. The key goes through stdin (--config -), never onto the command line.
get() {
  local resp
  if [ "${2:-}" = withkey ]; then
    resp="$(curl -sS --connect-timeout 10 -m 20 -w $'\n%{http_code}' --config - "${URL}$1" 2>/dev/null <<EOT
header = "Authorization: Bearer ${VLLM_API_KEY}"
EOT
    )"
  else
    resp="$(curl -sS --connect-timeout 10 -m 20 -w $'\n%{http_code}' "${URL}$1" 2>/dev/null)"
  fi
  CODE="${resp##*$'\n'}"; CODE="${CODE:-000}"
  BODY="${resp%$'\n'*}"
}

echo "Endpoint: ${URL}/v1/models   (Pod: ${POD_ID:-?}, source: ${SOURCE:-?})"

get /v1/models
case "$CODE" in
  401|403) ok "without a key: HTTP $CODE (the /v1 API is protected)" ;;
  200)     fail "WITHOUT a key the API answers 200: the server is OPEN to everyone. Stop it (scripts/stop-any.sh) and check the RunPod Secret VLLM_API_KEY" ;;
  000|404|429|5??) not_answering "$CODE" ;;
  *)       fail "without a key: unexpected HTTP $CODE (the protection could not be confirmed)" ;;
esac

get /v1/models withkey
case "$CODE" in
  200) ok "with your key: HTTP 200" ;;
  401|403) fail "with your key: HTTP $CODE. The server runs with a DIFFERENT key (an unresolved secret placeholder or a mistyped secret name?)" ;;
  000|404|429|5??) not_answering "$CODE" ;;
  *)   fail "with your key: unexpected HTTP $CODE" ;;
esac

if [ "$CODE" = 200 ]; then
  info="$(printf '%s' "$BODY" | python3 -c '
import json, sys
try:
    m = json.load(sys.stdin)["data"][0]
    print("%s\t%s\t%s" % (m.get("id", "?"), m.get("max_model_len", "?"), m.get("root", "?")))
except Exception:
    print("?\t?\t?")')"
  IFS=$'\t' read -r mid mlen mroot <<<"$info"
  want_ctx="${MAX_MODEL_LEN:-131072}"; want_model="${MODEL:-starkweatherdigital/qwen3.8-flash-next-nvfp4}"
  [ "$mid" = "qwen3.8-flash-next" ] && ok "served model: $mid" || fail "served model is '$mid', expected qwen3.8-flash-next"
  [ "$mlen" = "$want_ctx" ] && ok "context length: $mlen" || fail "context length is '$mlen', expected $want_ctx"
  [ "$mroot" = "$want_model" ] && ok "model root: $mroot" || warn "model root is '$mroot', expected $want_model"
fi

echo "Result: $([ "$fails" -eq 0 ] && echo "all checks passed" || echo "FAIL ($fails)")"
[ "$fails" -eq 0 ]
