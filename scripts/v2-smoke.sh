#!/usr/bin/env bash
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
# shellcheck source=scripts/_api.sh
source "$(dirname "$0")/_api.sh"

# Read-only smoke test: proves credentials + v2 routing without creating compute.
# Capture first so an HTTP error is not followed by a json.tool parse error.
response="$(api_get /pods)"
# Print only non-sensitive fields: the /pods response includes every Pod's env.
printf '%s' "$response" | python3 -c '
import json, sys
data = json.load(sys.stdin)
pods = data.get("pods") if isinstance(data, dict) else data
if not isinstance(pods, list):
    print("HTTP ok, but the response has an unexpected shape (no pods list)")
    sys.exit(0)
pods = [p for p in pods if isinstance(p, dict)]
keys = ("id", "name", "status", "desiredStatus", "costPerHr")
print("HTTP ok; %d pod(s)" % len(pods))
for p in pods:
    print("  " + "  ".join("%s=%s" % (k, p[k]) for k in keys if k in p))
'
