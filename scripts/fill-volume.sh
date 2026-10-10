#!/usr/bin/env bash
# Fills the Global Volume with the model, once: starts a cheap temporary GPU Pod (Global Volumes attach to GPU
# Pods only) that downloads the model onto its container disk (the download needs file locks, which a Global
# Volume does not have), copies it onto the volume, checks that every file arrived with the same size, and
# writes a marker file. This script then reads the result from the Pod's log and TERMINATES the Pod.
# The Pod is created through GraphQL (REST v2 cannot attach a Global Volume); see scripts/_storage.sh.
#
# DEFAULT IS A DRY RUN: it prints the request and creates nothing. Add --yes to create the Pod. The Pod bills
# its GPU per second until it ends (the cheapest card is about $0.25/h; the run takes tens of minutes).
#
# Usage: fill-volume.sh [--yes] [--token]
#   --yes     really create the Pod
#   --token   inject the HF_TOKEN RunPod Secret (HF_SECRET_NAME) for a private or gated repo (default: none)
# Environment:
#   GLOBAL_VOLUME_ID   REQUIRED with --yes: from `make volume ARGS='--global --yes'`
#   FILL_MODEL_REPO    default starkweatherdigital/qwen3.8-flash-next-nvfp4
#   FILL_REVISION      default 1b304e5f99de0faaf43c3a959f2b4000294bf65c (a fixed commit: reproducible)
#   FILL_TARGET        default /workspace/models/qwen3.8-flash-next-nvfp4 (becomes MODEL in .env)
#   FILL_GPU_IDS       comma separated GPU ids, any one of them will do (default: the cheapest secure cards)
#   FILL_DISK_GB       container disk, default 160 (the model is about 102 GiB and is held there once)
#   FILL_IMAGE         default python:3.12-slim
#   FILL_TIMEOUT       seconds the script inside the Pod may run, default 7200; it then ends itself
#
# SAFETY: the Pod ends by itself when its command ends or after FILL_TIMEOUT, and this script terminates it
# as soon as it has the result (also on Ctrl-C and SIGTERM). `make abort` uses `docker kill`, which no script
# can survive: the Pod then ends on its own at the latest after FILL_TIMEOUT. Check: scripts/v2-smoke.sh.
# The Pod's name starts with fill-global-volume-, never with POOL_PREFIX, so no pool guard counts it.
#
# The volume is only marked complete when the copy was verified: <target>/.fill-complete. A repeated run
# finds the marker and does nothing but report. Without it, the target may hold a partial copy: run again.
#
# Exit codes: 0 = dry run done, or the volume holds the verified model; 1 = failure (see the message; a Pod
# may have been created: it was terminated unless the message says otherwise); 2 = bad arguments/setup;
# 5 = no capacity for any of the GPUs (nothing was created); 6 = outcome unknown (no result in the log).
set -uo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"

YES=0; TOKEN=0
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;; --token) TOKEN=1 ;;
    *) echo "unknown argument: $a (see the header of this script)" >&2; exit 2 ;;
  esac
done

REPO="${FILL_MODEL_REPO:-starkweatherdigital/qwen3.8-flash-next-nvfp4}"
REV="${FILL_REVISION:-1b304e5f99de0faaf43c3a959f2b4000294bf65c}"
TARGET="${FILL_TARGET:-/workspace/models/qwen3.8-flash-next-nvfp4}"
GPUS="${FILL_GPU_IDS:-NVIDIA RTX 2000 Ada Generation,NVIDIA RTX A4000,NVIDIA RTX A4500,NVIDIA RTX A5000,NVIDIA RTX 4000 Ada Generation,NVIDIA GeForce RTX 3090}"
DISK="${FILL_DISK_GB:-160}"
IMAGE="${FILL_IMAGE:-python:3.12-slim}"
TMO="${FILL_TIMEOUT:-7200}"
GVOL="${GLOBAL_VOLUME_ID:-}"
case "$DISK$TMO" in ''|*[!0-9]*) echo "FILL_DISK_GB and FILL_TIMEOUT must be whole numbers" >&2; exit 2 ;; esac
{ [ "$DISK" -ge 130 ] && [ "$DISK" -le 1000 ]; } || { echo "FILL_DISK_GB must be between 130 and 1000 (the model needs about 110 GB)" >&2; exit 2; }
{ [ "$TMO" -ge 600 ] && [ "$TMO" -le 86400 ]; } || { echo "FILL_TIMEOUT must be between 600 and 86400 seconds" >&2; exit 2; }
case "$REPO$REV$TARGET$IMAGE$GVOL" in *[!A-Za-z0-9/._:@-]*) echo "FILL_MODEL_REPO, FILL_REVISION, FILL_TARGET, FILL_IMAGE and GLOBAL_VOLUME_ID may only hold letters, digits and / . _ : @ -" >&2; exit 2 ;; esac
case "$TARGET" in /workspace/?*) ;; *) echo "FILL_TARGET must be a directory below /workspace" >&2; exit 2 ;; esac
case "$GPUS" in *[!A-Za-z0-9\ ,._-]*) echo "FILL_GPU_IDS: letters, digits, spaces, commas, . _ - only" >&2; exit 2 ;; esac
if [ "$YES" -eq 1 ] && [ -z "$GVOL" ]; then
  echo "Set GLOBAL_VOLUME_ID in .env (make volume ARGS='--global --yes' creates one and prints it)." >&2
  exit 2
fi

# ---- the script that runs inside the Pod (passed as base64: no quoting problems)
inner="$(REPO="$REPO" REV="$REV" TARGET="$TARGET" python3 -c '
import os
tpl = r"""set -uo pipefail
T="@TARGET@"
trap "rc=\$?; [ \$rc -eq 0 ] || echo \"FILL_FAILED exit code \$rc\"" EXIT
echo "FILL_LOG start: $(date -u +%H:%M:%S), volume: $(df -h /workspace | tail -n1)"
if [ -f "$T/.fill-complete" ]; then echo "FILL_DONE already complete: $(cat "$T/.fill-complete")"; exit 0; fi
pip install -q -U "huggingface_hub[hf_xet]" || { echo "FILL_FAILED pip install"; exit 1; }
export HF_HOME=/root/hf HF_XET_HIGH_PERFORMANCE=1
echo "FILL_LOG download @REPO@ @REV@ to the container disk: $(date -u +%H:%M:%S)"
python3 -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id=\"@REPO@\", revision=\"@REV@\", local_dir=\"/root/model\")" || { echo "FILL_FAILED download"; exit 1; }
rm -rf /root/model/.cache
SRC="$(cd /root/model && find . -type f -printf "%s %P\n" | sort -k2)"
SRC_FILES="$(printf "%s\n" "$SRC" | wc -l)"; SRC_BYTES="$(printf "%s\n" "$SRC" | awk "{s+=\$1} END {print s}")"
echo "FILL_LOG downloaded $SRC_FILES files, $SRC_BYTES bytes: $(date -u +%H:%M:%S)"
mkdir -p "$T" || { echo "FILL_FAILED mkdir"; exit 1; }
( while sleep 180; do echo "FILL_LOG still copying: $(date -u +%H:%M:%S)"; done ) &
tick=$!
python3 - "$T" <<"PY" || { kill $tick; echo "FILL_FAILED copy"; exit 1; }
import os, shutil, sys
# no cp: it sets permission bits after each file, which a Global Volume refuses ("Operation not permitted")
dst, src = sys.argv[1], "/root/model"
for root, dirs, files in os.walk(src):
    rel = os.path.relpath(root, src)
    d = dst if rel == "." else os.path.join(dst, rel)
    os.makedirs(d, exist_ok=True)
    for f in files:
        shutil.copyfile(os.path.join(root, f), os.path.join(d, f))
PY
kill $tick
echo "FILL_LOG copied, verifying: $(date -u +%H:%M:%S)"
ok=0
for i in 1 2 3 4 5; do
  DST="$(cd "$T" && find . -type f ! -name .fill-complete -printf "%s %P\n" | sort -k2)"
  if [ "$SRC" = "$DST" ]; then ok=1; break; fi
  echo "FILL_LOG listing differs, try $i of 5 (object storage may lag)"; sleep 20
done
[ "$ok" = 1 ] || { echo "FILL_FAILED the copy on the volume differs from the download"; exit 1; }
echo "files=$SRC_FILES bytes=$SRC_BYTES repo=@REPO@ revision=@REV@ date=$(date -u +%FT%TZ)" > "$T/.fill-complete"
echo "FILL_DONE files=$SRC_FILES bytes=$SRC_BYTES target=$T"
"""
e = os.environ
print(tpl.replace("@TARGET@", e["TARGET"]).replace("@REPO@", e["REPO"]).replace("@REV@", e["REV"]))
')"
inner_b64="$(printf '%s' "$inner" | base64 | tr -d '\n')"
# timeout ends a hung run; the final sleep keeps the Pod up long enough for the last log lines to be read
cmd="bash -c 'echo ${inner_b64} | base64 -d > /tmp/fill.sh; timeout ${TMO} bash /tmp/fill.sh; echo FILL_EXIT=\$?; sleep 120'"

POD_NAME="fill-global-volume-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
vars="$(POD_NAME="$POD_NAME" IMAGE="$IMAGE" CMD="$cmd" DISK="$DISK" GPUS="$GPUS" GVOL="${GVOL:-<GLOBAL_VOLUME_ID>}" TOKEN="$TOKEN" HSEC="${HF_SECRET_NAME:-HF_TOKEN}" python3 -c '
import json, os
e = os.environ
i = {
    "name": e["POD_NAME"],
    "imageName": e["IMAGE"],
    "dockerArgs": e["CMD"],
    "containerDiskInGb": int(e["DISK"]),
    "cloudType": "SECURE",
    "startSsh": False,
    "gpuTypeIdList": [g.strip() for g in e["GPUS"].split(",") if g.strip()],
    "gpuCount": 1,
    "volumeMounts": [{"volumeId": e["GVOL"], "volumeType": "OBJECT_STORE_VOLUME", "mountPath": "/workspace"}],
}
if e["TOKEN"] == "1":
    i["env"] = [{"key": "HF_TOKEN", "value": "{{ RUNPOD_SECRET_%s }}" % e["HSEC"]}]
print(json.dumps({"input": i}))
')"

price="$(api_get /catalog/gpus 2>/dev/null | GPUS="$GPUS" python3 -c '
import json, os, sys
try:
    want = [g.strip() for g in os.environ["GPUS"].split(",")]
    ps = [g["price"]["secure"] for g in json.load(sys.stdin)["gpus"] if g.get("id") in want and (g.get("price") or {}).get("secure")]
    print("%.2f" % min(ps) if ps else "")
except Exception:
    print("")
' 2>/dev/null)"

echo "Temporary Pod to fill the Global Volume: $POD_NAME | one of: $GPUS | disk ${DISK} GB | image $IMAGE"
echo "  model $REPO @ $REV  ->  $TARGET  on Global Volume ${GVOL:-<GLOBAL_VOLUME_ID, not set>}"
printf '%s' "$vars" | python3 -c '
import json, sys
d = json.load(sys.stdin)["input"]
d["dockerArgs"] = d["dockerArgs"][:60] + " ... (base64 of the script below)"
print(json.dumps(d, indent=2))' | sed 's/^/  /'
echo "  The script that runs in the Pod:"
printf '%s\n' "$inner" | sed 's/^/    | /'
echo "  Cost: GPU ${price:+from about \$$price/h (catalog, secure cloud) }per second until the Pod ends; the download and copy take tens of minutes. The volume itself bills \$0.09/GB/month for what it holds."
if [ "$YES" -ne 1 ]; then
  echo
  echo "DRY RUN: nothing was created. Add --yes to create the Pod. It ends itself after at most ${TMO}s and this script terminates it."
  exit 0
fi

# ---- create. Never retried automatically.
POD_ID=""; DONE_TERMINATING=0
terminate_pod() {   # up to 3 tries; never leaves the Pod billing silently
  [ -n "$POD_ID" ] && [ "$DONE_TERMINATING" -eq 0 ] || return 0
  local i=1
  while [ "$i" -le 3 ]; do
    if api_post "/pods/$POD_ID/action" '{"action":"terminate"}' >/dev/null 2>&1; then
      DONE_TERMINATING=1; echo "Pod $POD_ID terminated."; return 0
    fi
    i=$((i + 1)); sleep 3
  done
  echo "COULD NOT TERMINATE Pod $POD_ID: it may still bill. Run: RUNPOD_POD_ID=$POD_ID make pod-terminate ARGS=--yes (it ends by itself after at most ${TMO}s plus 2 minutes)." >&2
}
on_signal() { trap '' INT TERM HUP; echo >&2; echo "Interrupted: terminating the Pod ..." >&2; terminate_pod; exit 130; }
trap on_signal INT TERM HUP
trap terminate_pod EXIT

gout="$(api_graphql 'mutation($input: PodFindAndDeployOnDemandInput) { podFindAndDeployOnDemand(input: $input) { id desiredStatus } }' "$vars" 2>&1)"
grc=$?
if [ "$grc" -ne 0 ]; then
  printf '%s\n' "$gout" >&2
  echo >&2
  api_auth_hint "$gout" && exit 1
  case "$(printf '%s' "$gout" | head -n1)" in
    "GraphQL error:"*)
      if printf '%s' "$gout" | grep -qiE "instances available|no capacity|out of capacity|does not have the resources"; then
        echo "No capacity for any of the GPUs right now. Nothing was created. Try again later, or set FILL_GPU_IDS." >&2; exit 5
      fi
      echo "The API rejected the request (see above). Nothing was created. This request shape was never run before." >&2; exit 1 ;;
    "HTTP 402"*) echo "Insufficient balance. Nothing was created." >&2; exit 1 ;;
    "HTTP 400"*|"HTTP 422"*) echo "The request failed validation (see above). Nothing was created." >&2; exit 1 ;;
    *) echo "The outcome is UNKNOWN: a Pod named $POD_NAME may exist and bill. Check scripts/v2-smoke.sh (look for the name)." >&2; exit 6 ;;
  esac
fi
POD_ID="$(printf '%s' "$gout" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["podFindAndDeployOnDemand"]["id"])
except Exception:
    print("")')"
case "$POD_ID" in
  ""|*[!a-z0-9]*) POD_ID=""; echo "The request was accepted but the response had no usable Pod id. A Pod named $POD_NAME may exist and bill: check scripts/v2-smoke.sh." >&2; exit 6 ;;
esac
echo "Created Pod $POD_ID ($POD_NAME). It bills now and is terminated when the result is known."

# ---- wait for the result in the Pod's log (the stream is cut after a short while on purpose)
read_log() {
  curl -sS -N --max-time 25 --connect-timeout 10 --config - "${BASE%/}/pods/${POD_ID}/logs?tail=300" 8>&- 9>&- <<EOT 2>/dev/null
header = "Authorization: Bearer ${RUNPOD_API_KEY}"
header = "Accept: text/event-stream"
EOT
}
deadline=$((SECONDS + TMO + 900)); last=""; read_fail=0
while [ "$SECONDS" -lt "$deadline" ]; do
  sleep 30
  log="$(read_log | grep -oE 'FILL_(LOG|DONE|FAILED|EXIT)[^"\\]*' | awk '!seen[$0]++')"
  new="$(printf '%s\n' "$log" | tail -n1)"
  if [ -n "$new" ] && [ "$new" != "$last" ]; then printf '%s\n' "$log" | tail -n 3 | sed "s/^/[$(date +%H:%M:%S)] /"; last="$new"; fi
  if printf '%s\n' "$log" | grep -q '^FILL_DONE'; then
    echo; printf '%s\n' "$log" | grep '^FILL_DONE' | tail -n1
    echo "The volume holds the verified model. Put this in .env:"
    echo "  STORAGE=global"
    echo "  GLOBAL_VOLUME_ID=$GVOL"
    echo "  MODEL=$TARGET"
    exit 0
  fi
  if printf '%s\n' "$log" | grep -q '^FILL_FAILED'; then
    echo >&2; printf '%s\n' "$log" | tail -n 8 >&2
    echo "Filling the volume FAILED (see above). The target may hold a partial copy; running again overwrites it." >&2
    exit 1
  fi
  info="$(api_pod_info "$POD_ID" 2>&1)"; irc=$?
  if [ "$irc" -ne 0 ]; then
    read_fail=$((read_fail + 1))
    if [ "$read_fail" -ge 10 ]; then echo "The Pod could not be read 10 times in a row; giving up." >&2; exit 6; fi
    continue
  fi
  read_fail=0
  IFS=$'\t' read -r _n status _c _d <<<"$info"
  case "$(printf '%s' "$status" | tr '[:lower:]' '[:upper:]')" in
    EXITED|TERMINATED)
      echo "The Pod ended ($status) without a result line in the log." >&2; printf '%s\n' "$log" | tail -n 8 >&2
      echo "Whether the volume was filled is UNKNOWN. Look at the log in the console, or run this again (a complete volume is detected and left alone)." >&2
      exit 6 ;;
  esac
done
echo "No result after $((TMO + 900)) s; the Pod is terminated now. Whether the volume was filled is UNKNOWN: run this again (a complete volume is detected and left alone)." >&2
exit 6
