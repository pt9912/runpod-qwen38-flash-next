# Sourced helper (no shebang, not executable): the Pod pool.
# The pool = every Pod whose name STARTS WITH POOL_PREFIX (default: qwen3.8-flash-next-b200) and that
# is not TERMINATED. Requires _api.sh to be sourced first.
POOL_PREFIX="${POOL_PREFIX:-qwen3.8-flash-next-b200}"
POOL_MEMBERS=""     # lines "id<TAB>name<TAB>status", most recently started first
POOL_ALL_NAMES=""   # names of ALL Pods in the account (for unique naming), one per line
POOL_ERR=""

# pool_refresh: reload the Pod list. Returns 1 (message in POOL_ERR) if the API call fails.
pool_refresh() {
  local resp parsed kind id name status
  resp="$(api_get /pods 2>&1)" || { POOL_ERR="$resp"; return 1; }
  parsed="$(printf '%s' "$resp" | PREFIX="$POOL_PREFIX" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
pods = d.get("pods") if isinstance(d, dict) else d
if not isinstance(pods, list):
    sys.exit(1)
def clean(v): return " ".join(str(v if v is not None else "").split())
members = []
for p in pods:
    if not isinstance(p, dict):
        continue
    name = clean(p.get("name"))
    # An empty status becomes UNKNOWN (counted as active: fail-safe); case is normalised.
    status = clean(p.get("status")).upper() or "UNKNOWN"
    if status == "TERMINATED":
        continue
    print("N\t-\t%s\t-" % name)
    if name.startswith(os.environ["PREFIX"]):
        members.append((clean(p.get("startedAt")), clean(p.get("id")), name, status))
for started, pid, name, status in sorted(members, key=lambda m: m[0], reverse=True):
    print("M\t%s\t%s\t%s" % (pid, name, status))
' 8>&- 9>&-)" || { POOL_ERR="unexpected response from GET /pods"; return 1; }
  POOL_MEMBERS=""; POOL_ALL_NAMES=""
  while IFS=$'\t' read -r kind id name status; do
    case "$kind" in
      M) POOL_MEMBERS+="$id"$'\t'"$name"$'\t'"$status"$'\n' ;;
      N) POOL_ALL_NAMES+="$name"$'\n' ;;
    esac
  done <<<"$parsed"
}

# pool_count: number of pool members.
pool_count() { if [ -z "$POOL_MEMBERS" ]; then echo 0; else printf '%s' "$POOL_MEMBERS" | grep -c .; fi; }

# pool_status_active STATUS: 0 if the status means "running or about to run". Fail-safe: EVERYTHING
# except EXITED, ERROR and TERMINATED counts (RUNNING, STARTING, PROVISIONING, and any unknown
# status), so an unexpected status can never lead to a second Pod.
pool_status_active() { case "$1" in EXITED|ERROR|TERMINATED) return 1 ;; *) return 0 ;; esac; }

# pool_active: print the first member whose status is active (see above); 1 if none.
pool_active() {
  local id name status
  while IFS=$'\t' read -r id name status; do
    [ -n "$id" ] || continue
    if pool_status_active "$status"; then printf '%s\t%s\t%s\n' "$id" "$name" "$status"; return 0; fi
  done <<<"$POOL_MEMBERS"
  return 1
}

# pool_other_active ID: print the first ACTIVE member whose id is not ID; 1 if there is none.
pool_other_active() {
  local id name status
  while IFS=$'\t' read -r id name status; do
    [ -n "$id" ] || continue
    if [ "$id" != "$1" ] && pool_status_active "$status"; then printf '%s\t%s\t%s\n' "$id" "$name" "$status"; return 0; fi
  done <<<"$POOL_MEMBERS"
  return 1
}

# pool_candidates: print the members that can be started (EXITED or ERROR), most recent first.
pool_candidates() {
  local id name status
  while IFS=$'\t' read -r id name status; do
    case "$status" in EXITED|ERROR) printf '%s\t%s\t%s\n' "$id" "$name" "$status" ;; esac
  done <<<"$POOL_MEMBERS"
}

# pool_pick_name: an unused name: POOL_PREFIX, else POOL_PREFIX-2, -3, ...
pool_pick_name() {
  local n=1 cand="$POOL_PREFIX"
  while printf '%s' "$POOL_ALL_NAMES" | grep -Fxq -- "$cand"; do
    n=$((n + 1)); cand="${POOL_PREFIX}-${n}"
  done
  printf '%s\n' "$cand"
}

# ---- lock: at most one start/create at a time on this machine.
# A kernel file lock on a fixed file, so there are no stale locks and no PID reuse:
#   - flock(1) if it exists (Linux), held on file descriptor 9;
#   - otherwise a small python3 helper (python3 is required anyway) that holds fcntl.flock and exits
#     as soon as this script is gone, so even a SIGKILL of the script frees the lock within a moment.
# It does not protect against runs on other machines (GitHub Actions has its own concurrency group).
POOL_LOCKFILE="${POOL_LOCKFILE:-${XDG_RUNTIME_DIR:-/tmp}/runpod-qwen38-pool-$(id -u).lock}"
POOL_LOCK_OWNED=0        # 1 = flock(1) held, 2 = python helper holds it
POOL_LOCK_HELPER=""
POOL_LOCK_HOLDER=""

# pool_lock_acquire: 0 = lock taken, 1 = another live run holds it (or the lock file cannot be opened).
pool_lock_acquire() {
  local kind rest
  if [ "${POOL_NO_FLOCK:-0}" != 1 ] && command -v flock >/dev/null 2>&1; then
    # append: opening must not truncate the holder's PID. The group carries the 2>/dev/null: a redirection on
    # `exec` itself would silence stderr of the whole script for good.
    { exec 9>>"$POOL_LOCKFILE"; } 2>/dev/null || return 1
    if flock -n 9; then
      printf '%s\n' "$$" >"$POOL_LOCKFILE" 2>/dev/null || true   # information only; the lock is the flock
      POOL_LOCK_OWNED=1; return 0
    fi
    POOL_LOCK_HOLDER="$(cat "$POOL_LOCKFILE" 2>/dev/null || true)"
    exec 9>&-
    return 1
  fi
  exec 8< <(POOL_LOCKFILE="$POOL_LOCKFILE" PARENT="$$" python3 -c '
import fcntl, os, sys, time
path, parent = os.environ["POOL_LOCKFILE"], int(os.environ["PARENT"])
try:
    f = open(path, "a")
    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    try:
        holder = open(path).read().strip() or "?"
    except OSError:
        holder = "?"
    sys.stdout.write("BUSY %s\n" % holder); sys.stdout.flush(); sys.exit(0)
open(path, "w").write("%d\n" % parent)     # information only
sys.stdout.write("LOCKED %d\n" % os.getpid()); sys.stdout.flush()
while True:                                   # hold the lock while the script lives
    try:
        os.kill(parent, 0)
    except OSError:
        break
    time.sleep(0.3)
') || return 1
  read -r -u 8 kind rest || { exec 8<&-; return 1; }
  if [ "$kind" = LOCKED ]; then POOL_LOCK_OWNED=2; POOL_LOCK_HELPER="$rest"; return 0; fi
  POOL_LOCK_HOLDER="$rest"; exec 8<&-
  return 1
}

# pool_lock_release: release only what this process owns.
pool_lock_release() {
  case "$POOL_LOCK_OWNED" in
    1) exec 9>&- ;;
    2) [ -z "$POOL_LOCK_HELPER" ] || kill "$POOL_LOCK_HELPER" 2>/dev/null; exec 8<&- ;;
  esac
  POOL_LOCK_OWNED=0
}

# ---- choosing the Pod to act on
# pool_active_count: number of active pool members.
pool_active_count() {
  local id name status n=0
  while IFS=$'\t' read -r id name status; do
    [ -n "$id" ] || continue
    if pool_status_active "$status"; then n=$((n + 1)); fi
  done <<<"$POOL_MEMBERS"
  echo "$n"
}

RESOLVED_POD_ID=""; RESOLVED_SOURCE=""
# pool_resolve_pod [ARG]: sets RESOLVED_POD_ID and RESOLVED_SOURCE. Precedence: ARG, the single ACTIVE
# pool Pod (needs RUNPOD_API_KEY), RUNPOD_POD_ID. Returns 0 = resolved, 1 = nothing (the caller may try
# QWEN_URL), 2 = several pool Pods are active (POOL_MEMBERS lists them; the caller must ask for an ID).
# This is what keeps a stale RUNPOD_POD_ID in .env from pointing a check at a stopped Pod.
pool_resolve_pod() {
  local arg="${1:-}" n act id name status
  RESOLVED_POD_ID=""; RESOLVED_SOURCE=""
  if [ -n "$arg" ]; then RESOLVED_POD_ID="$arg"; RESOLVED_SOURCE="argument"; return 0; fi
  if [ -n "${RUNPOD_API_KEY:-}" ] && pool_refresh 2>/dev/null; then
    n="$(pool_active_count)"
    if [ "$n" -eq 1 ]; then
      act="$(pool_active)"; IFS=$'\t' read -r id name status <<<"$act"
      RESOLVED_POD_ID="$id"; RESOLVED_SOURCE="the active pool Pod '$name' (status $status)"; return 0
    elif [ "$n" -gt 1 ]; then
      return 2
    fi
  fi
  if [ -n "${RUNPOD_POD_ID:-}" ]; then
    RESOLVED_POD_ID="$RUNPOD_POD_ID"; RESOLVED_SOURCE="RUNPOD_POD_ID"
    return 0
  fi
  return 1
}
