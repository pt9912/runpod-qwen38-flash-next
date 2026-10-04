#!/usr/bin/env bash
# Read-only: shows current stock of a GPU type (overall and per datacenter), so you
# can see whether the GPU is free, and where, before (re)deploying.
# Availability is an ordering hint, not a reservation: a create can still fail.
#
# Usage: gpu-availability.sh [GPU_MATCH] [DATACENTER_ID]
#   GPU_MATCH      case-insensitive GPU id/name (default: GPU_ID from .env, else B200); an exact id/name match wins,
#                  otherwise every GPU containing the text matches
#   DATACENTER_ID  only report this datacenter. Default: the datacenter of the Pod
#                  RUNPOD_POD_ID if that variable is set, otherwise the overall stock.
#                  "any" always means the overall stock (all datacenters).
#   GPU_COUNT      from the environment: with N>1 the stock is for N GPUs on one machine.
#
# Exit codes: 0 = in stock (in the given datacenter, if any), 2 = known GPU but no
# stock (a normal answer; `make gpu` maps it to success, see the Makefile), 4 = unknown GPU type or datacenter (typo?), 1 = API/transport error.
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
# shellcheck source=scripts/_api.sh
source "$(dirname "$0")/_api.sh"

MATCH="${1:-${GPU_ID:-B200}}"
DC="${2:-}"

# Datacenter: explicit value, "any" (= overall stock), or by default the Pod's own one
# (the Network Volume is bound to it, so stock elsewhere does not help).
dc_lc="$(printf '%s' "$DC" | tr '[:upper:]' '[:lower:]')"
if [ "$dc_lc" = "any" ]; then
  DC=""
elif [ -z "$DC" ] && [ -n "${RUNPOD_POD_ID:-}" ]; then
  pod_dc="$(api_pod_datacenter "$RUNPOD_POD_ID")"
  if [ "$pod_dc" != "?" ]; then
    DC="$pod_dc"
    echo "Datacenter: $DC (of Pod $RUNPOD_POD_ID; pass 'any' as the datacenter for the overall stock)" >&2
  else
    echo "Note: could not read the datacenter of Pod $RUNPOD_POD_ID; showing the overall stock." >&2
  fi
fi

# A datacenter that does not exist would look like "no stock"; reject it as a typo.
if [ -n "$DC" ]; then
  dcs_response="$(api_get "/catalog/datacenters")"
  printf '%s' "$dcs_response" | python3 -c '
import json, sys
dc = sys.argv[1].lower()
data = json.load(sys.stdin)
ids = sorted(d["id"] for d in (data.get("dataCenters") or []))
if dc not in [i.lower() for i in ids]:
    print("unknown datacenter %r. Known: %s" % (sys.argv[1], ", ".join(ids)), file=sys.stderr)
    sys.exit(4)
' "$DC" || exit $?
fi

# Capture first so an API failure is not followed by a JSON parse traceback.
# Note: a GPU without stock is absent from the per-datacenter catalog, so the
# GPU catalog is queried instead; it always lists the type and its overall stock.
COUNT_Q=""
case "${GPU_COUNT:-1}" in 1|"") ;; [2-8]) COUNT_Q="&count=$GPU_COUNT" ;; esac   # stock of N GPUs on ONE machine
response="$(api_get "/catalog/gpus?include=AVAILABILITY&product=POD${COUNT_Q}")"

printf '%s' "$response" | python3 -c '
import json, sys
shown, match, dc = sys.argv[1], sys.argv[1].lower(), sys.argv[2].lower()
data = json.load(sys.stdin)
gpus = data.get("gpus", data) if isinstance(data, dict) else data
exact = [g for g in gpus if match in (g["id"].lower(), g["name"].lower())]
hits = exact or [g for g in gpus if match in g["id"].lower() or match in g["name"].lower()]
if not exact and hits:
    print("note: no exact GPU id/name %r; showing every GPU type containing it" % match, file=sys.stderr)
if not hits:
    print("no GPU type in the catalog matches %r (typo?)" % match, file=sys.stderr)
    sys.exit(4)
in_stock = False
for g in hits:
    dcs = g.get("dataCenters") or []
    if dc:
        sel = [d for d in dcs if d["id"].lower() == dc]
        avail = sel[0]["availability"] if sel else "NONE"
        where = "in %s" % dc.upper()
    else:
        avail = g.get("availability", "NONE")
        where = "overall"
    price = (g.get("price") or {}).get("secure")
    print("%s (%s): %s %s%s" % (g["id"], g["name"], avail, where,
                                "   secure $%s/h" % price if price is not None else ""))
    if avail != "NONE":
        in_stock = True
        if not dc:
            for d in sorted(dcs, key=lambda d: d["id"]):
                print("    %-12s %s" % (d["id"], d["availability"]))
    else:
        print("    no stock" + (" in this datacenter" if dc else " in any datacenter"))
if not in_stock:
    print("")
    print("No %s in stock %s right now. That is a normal answer, not a failure; stock changes and is" % (shown, ("in " + dc.upper()) if dc else "anywhere"))
    print("only a hint. To be told when one is free (starts and bills nothing):")
    print("    make wait-gpu ARGS=\"%s%s\"" % (shown, " " + dc.upper() if dc else ""))
sys.exit(0 if in_stock else 2)
' "$MATCH" "$DC"
