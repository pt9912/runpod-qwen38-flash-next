#!/usr/bin/env bash
# Streams a Pod's container/system logs live: GET /v2/pods/{id}/logs (Server-Sent Events). Prints
# "<ts> [<source>] <line>" per event as it arrives; anything that is not a recognized SSE data
# frame (an HTTP error body, for example) is printed as-is so nothing is silently swallowed.
# Read-only: never starts, stops or changes anything on the Pod.
#
# The server can close the stream on its own (observed in practice; the API docs describe
# reconnecting via Last-Event-ID, which implies this is expected, not an error). This script
# reconnects automatically, resuming from the last event's id (a timestamp) so nothing in between
# is missed, and keeps doing so until you press Ctrl-C. A burst of reconnects that each fail
# within 3s (5 in a row) is treated as a real problem, not a routine reconnect, and stops the
# script -- otherwise a persistent failure (bad Pod ID, revoked key) would retry forever.
#
# Usage: pod-logs.sh [POD_ID] [--source container|system] [--tail N]
#   Which Pod: POD_ID if given; else the single ACTIVE pool Pod (needs RUNPOD_API_KEY); else
#   RUNPOD_POD_ID. If several pool Pods are active, give the POD_ID.
#   --source   container|system (default: both)
#   --tail     historical lines to backfill before the live stream starts (server default 100,
#              max 5000; 0 = no backfill, start live). Only used for the first connection: a
#              reconnect resumes from Last-Event-ID instead, which the API docs say takes
#              precedence over --tail anyway.
# Not through _api.sh: that helper buffers the whole response and has a 60s --max-time, both wrong
# for a long-lived stream; this uses its own curl -N (unbuffered, no timeout). The key goes through
# curl's stdin (--config -, a heredoc), same as _api.sh, so it never appears in `ps` or as an argv
# of any process (a process-substitution/printf intermediary would NOT have that property: its argv
# is visible in `ps` like any other command).
# Exit codes: 130 = interrupted (Ctrl-C, the normal way to stop this); 1 = 5 reconnects in a row
#   each failed within 3s (see above); 2 = bad arguments/setup. There is no successful/0 exit in
#   normal use: this only stops on Ctrl-C or that failure threshold. An HTTP-level error (e.g. 401)
#   does not by itself stop the script -- GET /logs streams either way, so its (non-SSE) response
#   body is printed as-is (see above); if that repeats it will hit the 5-fast-failures threshold.
# Note: run through `make logs`, this is NOT one of the four lock-guarded targets (create/start/
#   pod-start/start-when-free), so a Ctrl-C during `make logs` can leave the underlying `docker run`
#   container behind (Make does not forward signals to a recipe's children -- see the Makefile
#   header). Harmless here (read-only, no billing): find and stop it with
#   `docker ps --filter ancestor=runpod-qwen38-tools` / `docker kill <id>` if that happens.
set -uo pipefail
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"
# shellcheck source=scripts/_pool.sh
source "$HERE/_pool.sh"

SOURCE_FILTER=""; TAIL=""; POD_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE_FILTER="${2:-}"; shift 2 ;;
    --tail) TAIL="${2:-}"; shift 2 ;;
    -*) echo "unknown argument: $1 (see the header of this script)" >&2; exit 2 ;;
    *) POD_ARG="$1"; shift ;;
  esac
done
case "$SOURCE_FILTER" in ''|container|system) ;; *) echo "--source must be 'container' or 'system'" >&2; exit 2 ;; esac
if [ -n "$TAIL" ]; then
  case "$TAIL" in *[!0-9]*) echo "--tail must be a whole number" >&2; exit 2 ;; esac
  [ "$TAIL" -le 5000 ] || { echo "--tail must be <= 5000" >&2; exit 2; }
fi

pool_resolve_pod "$POD_ARG"; rc=$?
case "$rc" in
  0) POD_ID="$RESOLVED_POD_ID"; SOURCE="$RESOLVED_SOURCE" ;;
  2)
    echo "Several pool Pods are active; give the POD_ID:" >&2
    printf '%s' "$POOL_MEMBERS" | while IFS=$'\t' read -r i n st; do [ -z "$i" ] || printf '  %s  %s  %s\n' "$n" "$i" "$st" >&2; done
    exit 2
    ;;
  *) echo "Give a POD_ID, or start a pool Pod, or set RUNPOD_POD_ID" >&2; exit 2 ;;
esac
case "$POD_ID" in *[!a-z0-9]*) echo "Invalid Pod ID '$POD_ID' (expected lower-case letters and digits)" >&2; exit 2 ;; esac

qs=""
[ -z "$SOURCE_FILTER" ] || qs="source=${SOURCE_FILTER}"
if [ -n "$TAIL" ]; then [ -z "$qs" ] || qs="${qs}&"; qs="${qs}tail=${TAIL}"; fi
url="${BASE%/}/pods/${POD_ID}/logs"
[ -z "$qs" ] || url="${url}?${qs}"

echo "Streaming logs for Pod $POD_ID (source: $SOURCE). Ctrl-C to stop." >&2

# The last event's id (a timestamp), written by the python parser below via STATE_FILE so it
# survives across reconnects. Empty until the first event arrives.
STATE_FILE="$(mktemp)"
STOP=0; child=""
# A trap only stops the SCRIPT's own next steps; curl and python3 are separate processes in a
# pipeline the script started, and stay running (blocked reading the still-open connection) unless
# explicitly signaled too. So the pipeline runs in its own process group (set -m) and the trap
# kills that whole group, not just the shell -- same pattern as create-pod.sh/claude-qwen.sh.
on_signal() {
  STOP=1
  [ -z "$child" ] || kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null
}
trap on_signal INT TERM
trap 'rm -f "$STATE_FILE"' EXIT

LAST_ID=""; attempt=0; fast_fails=0
while [ "$STOP" -eq 0 ]; do
  attempt=$((attempt + 1))
  start=$SECONDS
  extra_hdr=""
  if [ -n "$LAST_ID" ]; then
    extra_hdr="header = \"Last-Event-ID: ${LAST_ID}\""
    [ "$attempt" -eq 1 ] || echo "Reconnecting (attempt $attempt), resuming from $LAST_ID ..." >&2
  fi

  # fd 8/9 closed: curl must never inherit a copy of the pool lock (see _pool.sh); harmless here
  # since this script never holds it. STATE_FILE is passed as argv[1] to the parser, not through
  # the environment, so it can't be confused with anything curl reads.
  set -m
  ( curl -sS -N --connect-timeout 10 --config - "$url" 8>&- 9>&- <<EOT |
header = "Authorization: Bearer ${RUNPOD_API_KEY}"
header = "Accept: text/event-stream"
${extra_hdr}
EOT
  python3 -u -c '
import sys, json

state_path = sys.argv[1]
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if not line or line.startswith(":"):
        continue
    if line.startswith("id:"):
        eid = line[len("id:"):].strip()
        if eid:
            try:
                with open(state_path, "w") as f:
                    f.write(eid)
            except OSError:
                pass
        continue
    if line.startswith("data:"):
        payload = line[len("data:"):].strip()
        if not payload:
            continue
        try:
            ev = json.loads(payload)
            print("%s [%s] %s" % (ev.get("ts", "?"), ev.get("source", "?"), ev.get("line", "")))
            continue
        except Exception:
            pass
    print(line)
' "$STATE_FILE"
  ) &
  child=$!
  set +m
  wait "$child"
  child=""

  [ "$STOP" -eq 0 ] || break
  [ ! -s "$STATE_FILE" ] || LAST_ID="$(cat "$STATE_FILE")"

  if [ $((SECONDS - start)) -lt 3 ]; then
    fast_fails=$((fast_fails + 1))
    if [ "$fast_fails" -ge 5 ]; then
      echo "5 reconnects in a row each ended within 3s; giving up. Check the messages above (an auth or Pod-ID problem?)." >&2
      exit 1
    fi
  else
    fast_fails=0
  fi
  sleep 1
done
echo "Interrupted." >&2
exit 130
