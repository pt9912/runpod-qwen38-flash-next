# Sourced helper (no shebang, not executable): RunPod REST v2 calls.
# Requires RUNPOD_API_KEY; BASE defaults to the v2 API.
BASE="${RUNPOD_BASE_URL:-https://api.runpod.io/v2}"

# _api_request METHOD PATH [JSON_BODY] -> prints the response body on 2xx;
# otherwise prints "HTTP <code> from METHOD URL" and the body to stderr, returns 1.
# The auth header goes through stdin (--config -) so the key never appears in
# `ps`. The status is read from `-w` (works with curl < 7.76, no --fail-with-body).
# No temp file is used, so nothing can be left behind on Ctrl-C.
_api_request() {
  local method="$1" path="$2" data="${3:-}" resp code body
  # Timeouts: a stalled connection must not hang pod-start/stop or a scheduled job.
  local -a args=(-sS --connect-timeout "${API_CONNECT_TIMEOUT:-10}" --max-time "${API_MAX_TIME:-60}" -w $'\n%{http_code}' -X "$method")
  if [ -n "$data" ]; then
    args+=(-H 'Content-Type: application/json' -d "$data")
  fi
  # fd 8/9 closed: curl must never inherit a copy of the pool lock (see _pool.sh). Harmless if
  # neither is open (most scripts never hold the lock).
  if ! resp="$(curl "${args[@]}" --config - "${BASE%/}${path}" 8>&- 9>&- <<EOT
header = "Authorization: Bearer ${RUNPOD_API_KEY}"
EOT
  )"; then
    return 1
  fi
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  case "$code" in
    2??) ;;
    *)
      echo "HTTP ${code:-?} from ${method} ${BASE%/}${path}" >&2
      printf '%s\n' "$body" >&2
      return 1
      ;;
  esac
  printf '%s' "$body"
}

# api_get PATH: read-only GET.
api_get() { _api_request GET "$1"; }

# api_post PATH JSON_BODY: state-changing POST (used by pod-start/stop).
api_post() { _api_request POST "$1" "$2"; }

# api_patch PATH JSON_BODY: state-changing PATCH (used to rename a Pod).
api_patch() { _api_request PATCH "$1" "$2"; }

# api_auth_hint OUTPUT: if OUTPUT (the captured stderr of a failed call) starts with
# "HTTP 401" or "HTTP 403" (our own message format), print an explanation and
# return 0; otherwise return 1 so the caller can show its own hint.
api_auth_hint() {
  case "$(printf '%s' "$1" | head -n1)" in
    "HTTP 401"*)
      echo "The API key was rejected (invalid or expired). Create a new key in the RunPod console (Settings > API Keys)." >&2
      ;;
    "HTTP 403"*)
      cat >&2 <<'MSG'
The API key is valid but not allowed to do this. Read calls (smoke test, pre-check --online) work
with a read-only key, but starting/stopping/creating Pods needs write access. Create a new API key
in the RunPod console (Settings > API Keys) with write access to Pods (or full access), and put
it in .env. This is a permission problem, not a full GPU.
MSG
      ;;
    *)
      return 1
      ;;
  esac
}

# api_pod_info ID: GET the Pod and print "name<TAB>status<TAB>cost<TAB>datacenter" (non-sensitive
# fields only; the Pod object also contains env). Fields missing in the response
# (or empty ones) are printed as "?". Returns 1 (message on stderr) if the GET fails.
api_pod_info() {
  local resp
  resp="$(api_get "/pods/$1")" || return 1
  printf '%s' "$resp" | python3 -c '
import json, sys
try:
    p = json.load(sys.stdin)
except Exception:
    p = {}
if not isinstance(p, dict):
    p = {}
def field(k):
    # No empty fields and no tabs/newlines: the caller splits on tabs.
    v = " ".join(str(p.get(k, "")).split())[:80]
    return v or "?"
print("\t".join(field(k) for k in ("name", "status", "cost", "dataCenterId")))
'
}

# api_pod_datacenter ID: print the Pod's datacenter id, or "?" if it cannot be determined
# (Pod unknown, API error, field missing). Never fails.
api_pod_datacenter() {
  local info name status cost dc
  info="$(api_pod_info "$1" 2>/dev/null)" || { echo "?"; return 0; }
  IFS=$'\t' read -r name status cost dc <<<"$info"
  echo "${dc:-?}"
}

# api_print_pod: read a 2xx action response on stdin and print id and status only.
# Parses defensively: the success body shape of the action endpoint is unverified,
# and an accepted action must never be reported as a failure.
api_print_pod() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    p = json.loads(raw)
except Exception:
    p = None
if isinstance(p, dict) and ("id" in p or "status" in p):
    print("Pod %s: status=%s" % (p.get("id", "?"), p.get("status", "?")))
else:
    print("Action accepted (HTTP 2xx); response has no status. Check with scripts/v2-smoke.sh.")
'
}
