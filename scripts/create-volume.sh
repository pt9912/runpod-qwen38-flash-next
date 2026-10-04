#!/usr/bin/env bash
# Creates the Network Volume that holds the model and the vLLM cache (POST /v2/network-volumes), or
# lists the existing ones. A volume is a BILLABLE, PERSISTENT resource: it costs about $0.07/GB/month
# (standard tier, under 1 TB; RunPod's published rate, not read from the API) whether or not a Pod
# runs, until it is deleted. Its size can only grow later, never shrink, and its datacenter is fixed.
#
# DEFAULT IS A DRY RUN: it prints the request and creates nothing. Add --yes to create.
#
# Usage: create-volume.sh --dc DATACENTER [--size GB] [--name NAME] [--type TIER] [--yes]
#        create-volume.sh --list
#   --dc DATACENTER   REQUIRED (or DATACENTER in .env): where the volume lives. The Pod is always placed
#                     in the volume's datacenter, so pick one with stock of your GPU (see `make gpu`).
#   --size GB         default 150 (VOLUME_SIZE_GB): the model is 109.23 GB plus a few GB of vLLM cache
#   --name NAME       default qwen3.8-flash-next (VOLUME_NAME); refused if a volume has this name
#   --type TIER       STANDARD (default) or HIGH_PERFORMANCE (more expensive, only in some datacenters).
#                     STANDARD is sent explicitly: omitting it would use the datacenter's default tier.
#   --list            show your existing volumes and exit
#   --yes             really create the volume
#
# Exit codes: 0 = dry run done, volume created, or list shown; 1 = failure (nothing was created unless
# the message says the outcome is unknown); 2 = bad arguments/setup; 3 = a volume with this name
# already exists (nothing created).
set -uo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"

YES=0; LIST=0
DC="${DATACENTER:-}"
SIZE="${VOLUME_SIZE_GB:-150}"
NAME="${VOLUME_NAME:-qwen3.8-flash-next}"
TYPE="STANDARD"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --list) LIST=1 ;;
    --dc|--size|--name|--type)
      [ "$#" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }
      case "$1" in --dc) DC="$2" ;; --size) SIZE="$2" ;; --name) NAME="$2" ;; --type) TYPE="$2" ;; esac
      shift ;;
    *) echo "unknown argument: $1 (see the header of this script)" >&2; exit 2 ;;
  esac
  shift
done

# On failure returns 1 and prints the error message (not volumes) on stdout.
# Prints "id<TAB>name<TAB>size<TAB>datacenter<TAB>type" per volume. Accepts the v2 shape
# ({"networkVolumes": [...]}) and, defensively, a bare list or {"items": [...]}.
list_volumes() {
  local resp
  resp="$(api_get /network-volumes 2>&1)" || { printf '%s\n' "$resp"; return 1; }   # on failure: the message goes to stdout
  printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
vols = d if isinstance(d, list) else (d.get("networkVolumes") or d.get("items") or []) if isinstance(d, dict) else []
if not isinstance(vols, list):
    sys.exit(3)
def f(v, *keys):
    for k in keys:
        if v.get(k) not in (None, ""):
            return " ".join(str(v[k]).split())[:80]
    return "?"
for v in vols:
    if isinstance(v, dict):
        print("\t".join((f(v, "id"), f(v, "name"), f(v, "size"), f(v, "dataCenter", "dataCenterId"), f(v, "type"))))
'
}

if [ "$LIST" -eq 1 ]; then
  vols="$(list_volumes)" || { printf '%s\n' "$vols" >&2; api_auth_hint "$vols" && exit 1; echo "Could not list the Network Volumes." >&2; exit 1; }
  if [ -z "$vols" ]; then echo "No Network Volumes."; exit 0; fi
  printf '%-26s %-30s %8s  %-12s %s\n' ID NAME "SIZE(GB)" DATACENTER TYPE
  printf '%s\n' "$vols" | while IFS=$'\t' read -r i n s d t; do printf '%-26s %-30s %8s  %-12s %s\n' "$i" "$n" "$s" "$d" "$t"; done
  exit 0
fi

# ---- validate the inputs
[ -n "$DC" ] || { echo "Give --dc DATACENTER (or set DATACENTER in .env). Pick one with stock of your GPU: make gpu" >&2; exit 2; }
case "$DC" in *[!A-Za-z0-9-]*) echo "Invalid datacenter '$DC' (expected letters, digits and dashes, e.g. EU-RO-1)" >&2; exit 2 ;; esac
case "$SIZE" in ''|*[!0-9]*) echo "--size must be a whole number of GB" >&2; exit 2 ;; esac
{ [ "$SIZE" -ge 1 ] && [ "$SIZE" -le 4000 ]; } || { echo "--size must be between 1 and 4000 GB" >&2; exit 2; }
case "$TYPE" in STANDARD|HIGH_PERFORMANCE) ;; *) echo "--type must be STANDARD or HIGH_PERFORMANCE" >&2; exit 2 ;; esac
[ -n "$NAME" ] || { echo "--name must not be empty" >&2; exit 2; }
if [ "$SIZE" -lt 120 ]; then
  echo "Warning: $SIZE GB is too small for the 109.23 GB model plus caches (150 GB is the recommended minimum)." >&2
fi

# ---- the datacenter must exist and support this volume tier (read-only; a failed read only warns)
dcs="$(api_get /catalog/datacenters 2>&1)"; drc=$?
if [ "$drc" -ne 0 ]; then
  printf '%s\n' "$dcs" >&2
  api_auth_hint "$dcs" && exit 1
  echo "Warning: could not read the datacenter list; the datacenter and tier were NOT checked." >&2
else
  chk="$(printf '%s' "$dcs" | DC="$DC" TYPE="$TYPE" python3 -c '
import json, os, sys
dc, tier = os.environ["DC"], os.environ["TYPE"]
try:
    d = json.load(sys.stdin)
    lst = d.get("dataCenters") if isinstance(d, dict) else d
    by = {x.get("id"): x for x in lst if isinstance(x, dict)}
except Exception:
    print("UNREADABLE"); sys.exit(0)
if dc not in by:
    print("UNKNOWN " + ", ".join(sorted(k for k in by if k)))
elif not by[dc].get("networkVolumeTypes"):
    print("NOVOLUMES")
elif tier not in by[dc]["networkVolumeTypes"]:
    print("NOTIER " + ", ".join(by[dc]["networkVolumeTypes"]))
else:
    print("OK")
')"
  case "$chk" in
    OK) ;;
    UNREADABLE) echo "Warning: the datacenter list had an unexpected shape; the datacenter and tier were NOT checked." >&2 ;;
    UNKNOWN*) echo "Unknown datacenter '$DC'. Known: ${chk#UNKNOWN }" >&2; exit 2 ;;
    NOVOLUMES) echo "Datacenter $DC does not support Network Volumes." >&2; exit 2 ;;
    NOTIER*) echo "Datacenter $DC does not offer the $TYPE tier (it offers: ${chk#NOTIER })." >&2; exit 2 ;;
  esac
fi

# ---- refuse a duplicate name (names need not be unique for RunPod, but two volumes of this name would
# make the one in .env ambiguous and double the bill)
vols="$(list_volumes)" || { printf '%s\n' "$vols" >&2; api_auth_hint "$vols" && exit 1; echo "Could not list the existing Network Volumes; nothing was created." >&2; exit 1; }
if printf '%s\n' "$vols" | cut -f2 | grep -Fxq -- "$NAME"; then
  echo "A Network Volume named '$NAME' already exists:" >&2
  printf '%s\n' "$vols" | awk -F'\t' -v n="$NAME" '$2 == n { printf "  %s  %s GB  %s  %s\n", $1, $3, $4, $5 }' >&2
  echo "Nothing was created. Use that one (put its ID in .env as NETWORK_VOLUME_ID), or pass another --name." >&2
  exit 3
fi

body="$(NAME="$NAME" SIZE="$SIZE" DC="$DC" TYPE="$TYPE" python3 -c '
import json, os
e = os.environ
print(json.dumps({"name": e["NAME"], "size": int(e["SIZE"]), "dataCenter": e["DC"], "type": e["TYPE"]}))
')"
cost="$(python3 -c 'import sys; print("%.2f" % (int(sys.argv[1]) * 0.07))' "$SIZE")"

echo "Network Volume to create: $NAME | $SIZE GB | datacenter $DC | tier $TYPE"
printf '%s' "$body" | python3 -m json.tool | sed 's/^/  /'
echo "  Cost: about \$$cost/month at the standard rate of \$0.07/GB (published rate; HIGH_PERFORMANCE costs more), billed hourly, also while no Pod runs."
echo "  It can only be enlarged later, never shrunk, and it cannot move to another datacenter."

if [ "$YES" -ne 1 ]; then
  echo
  echo "DRY RUN: nothing was created. Add --yes to create the volume. Check the stock in $DC first: make gpu ARGS='"${GPU_ID:-B200}" $DC'"
  exit 0
fi

# ---- create. Never retried automatically: a request that may have arrived must not be sent twice.
out="$(api_post /network-volumes "$body" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" >&2
  echo >&2
  api_auth_hint "$out" && exit 1
  case "$(printf '%s' "$out" | head -n1)" in
    "HTTP 400"*|"HTTP 422"*) echo "The API rejected the request (see above). Nothing was created." >&2 ;;
    "HTTP 402"*) echo "Insufficient balance. Nothing was created." >&2 ;;
    "HTTP 429"*|"HTTP 5"*) echo "The API is throttling or failed. Whether a volume was created is NOT certain: check with make volume ARGS=--list before retrying." >&2 ;;
    "HTTP "*) echo "Volume creation failed (see above)." >&2 ;;
    *) echo "The connection failed while the request may already have been sent: the outcome is UNKNOWN. Check before retrying: make volume ARGS=--list" >&2 ;;
  esac
  exit 1
fi

new_id="$(printf '%s' "$out" | python3 -c 'import json,sys
try:
    p = json.load(sys.stdin); print(p.get("id", "") if isinstance(p, dict) else "")
except Exception:
    print("")')"
if [ -z "$new_id" ]; then
  echo "The request was accepted but the response had no volume id. Find it: make volume ARGS=--list" >&2
  exit 1
fi
echo
echo "Created Network Volume $new_id ($SIZE GB in $DC). It is billing now."
echo "Add this to your .env:  NETWORK_VOLUME_ID=$new_id"
