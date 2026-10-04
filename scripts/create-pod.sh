#!/usr/bin/env bash
# Creates the Qwen3.8-Flash-Next Pod through the documented REST v2 API (POST /v2/pods) and then
# verifies it with scripts/verify-pod.sh. Every field is explicit and checked afterwards.
#
# DEFAULT IS A DRY RUN: it prints the request and creates nothing. Add --yes to create.
# A created Pod BILLS the GPU at once until you stop or terminate it.
#
# Usage: create-pod.sh [--yes] [--online] [--ssh] [--force] [--terminate-on-fail]
#   --yes      really create the Pod
#   --force    create even if a Pod of the pool (name starts with POOL_PREFIX) is already running/active
#              (default: refuse, because two pool Pods must never run at once)
#   --terminate-on-fail   if the created Pod fails verification, terminate it (default: stop it and
#              rename it to failed-<name>-<id>, which takes it out of the pool and keeps it for inspection)
#   --online   allow model downloads: HF_HUB_OFFLINE is not set and the HF_TOKEN secret is injected
#   --ssh      also expose 22/tcp and start ssh (default: off, only 8000/http is exposed). Needs SSH public
#              keys registered in your RunPod account and an sshd in the image (not verified for this image).
#              The environment variable CREATE_POD_SSH=1 does the same (start-any.sh passes it on).
# Environment (all optional):
#   STORAGE             network (default) or global; see scripts/_storage.sh. With global, the model is on a
#                       Global Volume and the caches on the container disk. The API cannot attach a Global
#                       Volume, so --yes is refused: the dry run prints the settings for the web console.
#   HF_HOME_DIR / VLLM_CACHE_DIR   default: under /workspace (network), under /root/.cache (global)
#   NETWORK_VOLUME_ID   REQUIRED with STORAGE=network: the ID of your Network Volume (put it in .env)
#   POD_NAME            default: qwen3.8-flash-next; must start with POOL_PREFIX (else no pool guard
#                        ever sees it), unless --force
#   GPU_ID              default: NVIDIA B200 (check the exact id with `make gpu`)
#   GPU_COUNT           default: 1; N>1 gives the Pod N GPUs of the same machine and runs vLLM with
#                       tensor parallelism N (TP=N, CUDA_VISIBLE_DEVICES=0..N-1). Not validated with this recipe.
#   VLLM_EXTRA_ARGS     optional: extra `vllm serve` arguments appended by the image entrypoint
#   DATACENTER          default: the datacenter of the Network Volume (required to place the Pod there);
#                       with STORAGE=global: unset = any datacenter
#   VLLM_SECRET_NAME / HF_SECRET_NAME   RunPod Secret names (defaults VLLM_API_KEY / HF_TOKEN)
#   CONTAINER_DISK_GB   default: 50
#   REMOTE_IMAGE        REQUIRED: the patched x86_64 vLLM image (image/), ideally pinned by digest
#   MODEL               default: starkweatherdigital/qwen3.8-flash-next-nvfp4
#   MAX_MODEL_LEN       default: 131072; GPU_MEMORY_UTILIZATION default 0.90
#   MAX_NUM_SEQS        default: 16: concurrent sequences. The KV cache holds a fixed number of tokens, so
#                       MAX_NUM_SEQS x MAX_MODEL_LEN should not exceed it (vLLM prints "Maximum concurrency")
#   YARN_FACTOR         optional: static YaRN factor (4.0 for 1M, 2.0 for 524288) to go beyond the native
#                       262144; needs MAX_MODEL_LEN above 262144 and <= 262144 x factor. Unset = no scaling
#   PLE_MMAP            default 0; 1 needs MODEL=<local dir> and is not validated on B200
#                       (with STORAGE=global, MODEL must be a local dir anyway, e.g. /workspace/models/...)
#
# Exit codes: 0 = dry run done, or Pod created and verified; 1 = failure, or the Pod was created
# but FAILED verification (it is then stopped and renamed, or terminated; see the messages);
# 2 = bad arguments/setup; 3 = a Pod with this name exists, or a pool Pod is active (nothing
# created); 4 = another start/create is in progress on this machine (nothing created);
# 5 = no capacity (nothing created); 6 = created and running, but verification could not run (the Pod
# could not be read): it is left untouched, check it with verify-pod.sh.
set -uo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"
# shellcheck source=scripts/_pool.sh
source "$HERE/_pool.sh"
# shellcheck source=scripts/_storage.sh
source "$HERE/_storage.sh"

YES=0; ONLINE=0; SSH=0; FORCE=0; TERMINATE_ON_FAIL=0
[ "${CREATE_POD_SSH:-0}" != 1 ] || SSH=1
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;; --online) ONLINE=1 ;; --ssh) SSH=1 ;; --force) FORCE=1 ;; --terminate-on-fail) TERMINATE_ON_FAIL=1 ;;
    *) echo "unknown argument: $a (see the header of this script)" >&2; exit 2 ;;
  esac
done

if [ "$STORAGE" = global ] && [ "$YES" -eq 1 ]; then
  echo "STORAGE=global: the RunPod API cannot attach a Global Volume (v1 and v2, checked 2026-10-04), so a Pod" >&2
  echo "created here would have no model. Nothing was created. Run without --yes: the dry run prints the" >&2
  echo "settings to enter in the web console (Pods > Deploy)." >&2
  exit 2
fi
VOLUME=""
if [ "$STORAGE" = network ]; then
  VOLUME="${NETWORK_VOLUME_ID:-}"
  [ -n "$VOLUME" ] || { echo "Set NETWORK_VOLUME_ID (the ID of your Network Volume) in .env (or STORAGE=global)" >&2; exit 2; }
fi
POD_NAME_GIVEN="${POD_NAME:-}"
POD_NAME="${POD_NAME:-qwen3.8-flash-next}"
GPU_ID="${GPU_ID:-NVIDIA B200}"
GPU_COUNT="${GPU_COUNT:-1}"
case "$GPU_COUNT" in [1-8]) ;; *) echo "GPU_COUNT must be a whole number from 1 to 8" >&2; exit 2 ;; esac
DISK="${CONTAINER_DISK_GB:-50}"
case "$DISK" in ''|*[!0-9]*) echo "CONTAINER_DISK_GB must be a whole number" >&2; exit 2 ;; esac
case "$POD_NAME" in
  "$POOL_PREFIX"*) ;;
  *)
    if [ "$FORCE" -ne 1 ]; then
      echo "POD_NAME '$POD_NAME' does not start with POOL_PREFIX ('$POOL_PREFIX'): every pool guard (start-any.sh, stop-any.sh, pod-start.sh) would never see this Pod, so a second one could be started or created alongside it. Use a name starting with '$POOL_PREFIX', or pass --force to create it anyway." >&2
      exit 2
    fi
    echo "Note: POD_NAME '$POD_NAME' does not start with POOL_PREFIX ('$POOL_PREFIX'); pool guards will never see this Pod (--force)." >&2
    ;;
esac

# 1. The Pod must be placed in the volume's datacenter (a Global Volume has none).
DC="${DATACENTER:-}"
if [ -z "$DC" ] && [ "$STORAGE" = network ]; then
  vol="$(api_get "/network-volumes/$VOLUME" 2>&1)" || { printf '%s\n' "$vol" >&2; echo "Could not read Network Volume $VOLUME." >&2; exit 1; }
  DC="$(printf '%s' "$vol" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("dataCenter") or d.get("dataCenterId") or "")' 2>/dev/null)"
  [ -n "$DC" ] || { echo "Could not determine the datacenter of volume $VOLUME; set DATACENTER." >&2; exit 1; }
fi

# 2. Only one create at a time on this machine (start-any.sh holds the lock and sets POOL_LOCK_HELD).
if [ "$YES" -eq 1 ] && [ "${POOL_LOCK_HELD:-0}" != 1 ]; then
  trap pool_lock_release EXIT
  pool_lock_acquire || { echo "Another start/create is in progress on this machine (PID ${POOL_LOCK_HOLDER:-?}, lock $POOL_LOCKFILE). Nothing was created." >&2; exit 4; }
fi

# 3. Refuse to create a duplicate name, and (without --force) a second active Pod of the pool.
pool_refresh || { printf '%s\n' "$POOL_ERR" >&2; echo "Could not list Pods." >&2; exit 1; }
if printf '%s' "$POOL_ALL_NAMES" | grep -Fxq -- "$POD_NAME"; then
  if [ "$FORCE" -eq 1 ] && [ -z "${POD_NAME_GIVEN:-}" ]; then
    # --force with the default name: take the next free pool name instead of failing
    POD_NAME="$(pool_pick_name)"
    echo "The default name is taken; --force uses the free name '$POD_NAME'." >&2
  else
    echo "A Pod named '$POD_NAME' already exists." >&2
    echo "Nothing was created. Terminate it (scripts/pod-terminate.sh), or set POD_NAME." >&2
    exit 3
  fi
fi
if [ "$FORCE" -ne 1 ] && act="$(pool_active)"; then
  IFS=$'\t' read -r a_id a_name a_status <<<"$act"
  echo "A pool Pod is already active: '$a_name' ($a_id), status $a_status. Two pool Pods must not run at once." >&2
  echo "Nothing was created. Stop it (scripts/stop-any.sh), or use --force if you really want a second one." >&2
  exit 3
fi

# 3. Build the request body (no secret values: only RunPod Secret references).
# The image (image/Dockerfile) has serve-b200 as its ENTRYPOINT and reads its settings from the
# environment, so the body sets env variables and no cmd (a cmd would override the entrypoint).
IMAGE="${REMOTE_IMAGE:-}"
[ -n "$IMAGE" ] || { echo "Set REMOTE_IMAGE (your built image, see image/README.md; pin it by digest) in .env" >&2; exit 2; }
case "$IMAGE" in
  *jstarkg/vllm-gb10*|*sm121*) echo "REMOTE_IMAGE '$IMAGE' is the arm64/sm121 (DGX Spark) image: it cannot run on a B200." >&2; exit 2 ;;
esac
MODEL="${MODEL:-starkweatherdigital/qwen3.8-flash-next-nvfp4}"
CTX="${MAX_MODEL_LEN:-131072}"
case "$CTX" in ''|*[!0-9]*) echo "MAX_MODEL_LEN must be a whole number" >&2; exit 2 ;; esac
SEQS="${MAX_NUM_SEQS:-16}"
case "$SEQS" in ''|*[!0-9]*) echo "MAX_NUM_SEQS must be a whole number" >&2; exit 2 ;; esac
{ [ "$SEQS" -ge 1 ] && [ "$SEQS" -le 256 ]; } || { echo "MAX_NUM_SEQS must be between 1 and 256" >&2; exit 2; }
YARN="${YARN_FACTOR:-}"
if [ -n "$YARN" ]; then
  case "$YARN" in ''|*[!0-9.]*|*.*.*|.*|*.|0*) echo "YARN_FACTOR must be a number such as 2.0 or 4.0" >&2; exit 2 ;; esac
  python3 -c 'import sys; f, c = float(sys.argv[1]), int(sys.argv[2]); sys.exit(0 if f > 1 and 262144 < c <= 262144 * f else 1)' "$YARN" "$CTX" \
    || { echo "YARN_FACTOR=$YARN needs a factor above 1 and MAX_MODEL_LEN between 262145 and 262144 x factor (now $CTX)" >&2; exit 2; }
fi
if [ "$STORAGE" = global ]; then
  case "$MODEL" in
    /*) ;;
    *) echo "STORAGE=global needs MODEL to be the model's directory on the Global Volume (for example /workspace/models/qwen3.8-flash-next-nvfp4), not a Hugging Face id: a download onto the Global Volume is not safe (no file locks, no atomic rename) and one onto the container disk would repeat on every new Pod." >&2; exit 2 ;;
  esac
fi
MMAP="${PLE_MMAP:-0}"
case "$MMAP" in 0|1) ;; *) echo "PLE_MMAP must be 0 or 1" >&2; exit 2 ;; esac
if [ "$MMAP" = 1 ]; then
  case "$MODEL" in
    /*) ;;
    *) echo "PLE_MMAP=1 needs MODEL to be a local directory (for example /workspace/models/qwen3.8-flash-next-nvfp4), not a Hugging Face id." >&2; exit 2 ;;
  esac
fi
body="$(HF_HOME_DIR="$HF_HOME_DIR" VLLM_CACHE_DIR="$VLLM_CACHE_DIR" POD_NAME="$POD_NAME" GPU_ID="$GPU_ID" GPU_COUNT="$GPU_COUNT" VOLUME="$VOLUME" DC="$DC" DISK="$DISK" ONLINE="$ONLINE" SSH="$SSH" \
  IMAGE="$IMAGE" MODEL="$MODEL" CTX="$CTX" SEQS="$SEQS" MMAP="$MMAP" YARN="$YARN" GPU_MEM="${GPU_MEMORY_UTILIZATION:-0.90}" \
  VSEC="${VLLM_SECRET_NAME:-VLLM_API_KEY}" HSEC="${HF_SECRET_NAME:-HF_TOKEN}" python3 -c '
import json, os
e = os.environ
env = {
    "HF_HOME": e["HF_HOME_DIR"],
    "HF_HUB_CACHE": e["HF_HOME_DIR"] + "/hub",
    "HF_XET_HIGH_PERFORMANCE": "1",
    "CUDA_VISIBLE_DEVICES": ",".join(str(i) for i in range(int(e["GPU_COUNT"]))),
    "VLLM_ENGINE_READY_TIMEOUT_S": "3600",
    "VLLM_CACHE_ROOT": e["VLLM_CACHE_DIR"],
    "VLLM_API_KEY": "{{ RUNPOD_SECRET_%s }}" % e["VSEC"],
    # read by serve-b200 (image/serve-b200.sh)
    "MODEL": e["MODEL"],
    "SERVED_MODEL_NAME": "qwen3.8-flash-next",
    "CTX": e["CTX"],
    "GPU_MEM": e["GPU_MEM"],
    "TP": e["GPU_COUNT"],
    "SEQS": e["SEQS"],
    "MTP": "1",
    "CACHE": "1",
    "MMAP": e["MMAP"],
    "PREWARM": e["MMAP"],
}
if e.get("YARN"):
    env["YARN_FACTOR"] = e["YARN"]
if e.get("VLLM_EXTRA_ARGS"):
    env["VLLM_EXTRA_ARGS"] = e["VLLM_EXTRA_ARGS"]
if e["ONLINE"] == "1":
    env["HF_TOKEN"] = "{{ RUNPOD_SECRET_%s }}" % e["HSEC"]
else:
    env["HF_HUB_OFFLINE"] = "1"
body = {
    "name": e["POD_NAME"],
    "image": e["IMAGE"],
    "env": env,
    "ports": ["8000/http"] + (["22/tcp"] if e["SSH"] == "1" else []),
    "disk": int(e["DISK"]),
    "cloud": "SECURE",
    "gpu": {"id": e["GPU_ID"], "count": int(e["GPU_COUNT"])},
    "startSsh": e["SSH"] == "1",
}
if e["VOLUME"]:
    body["mounts"] = {"network": [{"volumeId": e["VOLUME"], "path": "/workspace"}]}
if e["DC"]:
    body["dataCenterIds"] = [e["DC"]]
print(json.dumps(body))
')"

if [ "$STORAGE" = global ]; then
  echo "Pod to create IN THE WEB CONSOLE (STORAGE=global): $POD_NAME | ${GPU_COUNT}x $GPU_ID | datacenter ${DC:-any} | Global Volume on /workspace | caches on the container disk"
  echo
  printf '%s' "$body" | python3 -c '
import json, sys
b = json.load(sys.stdin)
print("Enter these values (Pods > Deploy; Secure Cloud):")
print("  Pod name ......... %s   (must start with the pool prefix, or no script finds it)" % b["name"])
print("  GPU .............. %dx %s%s" % (b["gpu"]["count"], b["gpu"]["id"], ", datacenter %s" % b["dataCenterIds"][0] if b.get("dataCenterIds") else ""))
print("  Image ............ %s" % b["image"])
print("  Start command .... leave empty (the image entrypoint reads the env below)")
print("  Container disk ... %d GB" % b["disk"])
print("  Storage .......... + Add volume: your Global Volume, mount path /workspace; no Network Volume")
print("  Expose ports ..... HTTP 8000" + (", TCP 22" if "22/tcp" in b["ports"] else ""))
print("  Env (Raw editor, one per line):")
for k, v in b["env"].items():
    print("    %s=%s" % (k, v))
'
  echo
  echo "Then: make verify, make wait-ready, make check (they find the Pod by its name)."
  echo "DRY RUN: nothing was created. The API cannot attach a Global Volume, so --yes is refused with STORAGE=global."
  exit 0
fi

echo "Pod to create: $POD_NAME | ${GPU_COUNT}x $GPU_ID | datacenter $DC | volume $VOLUME on /workspace | disk ${DISK} GB | ssh $([ "$SSH" = 1 ] && echo on || echo off) | $([ "$ONLINE" = 1 ] && echo "downloads allowed (HF_TOKEN secret)" || echo "offline mode")"
printf '%s' "$body" | python3 -m json.tool | sed 's/^/  /'

if [ "$YES" -ne 1 ]; then
  echo
  echo "Stock of $GPU_ID in $DC (a hint, not a reservation):"
  "$HERE/gpu-availability.sh" "$GPU_ID" "$DC" 2>&1 | sed 's/^/  /'
  echo
  echo "DRY RUN: nothing was created. Add --yes to create the Pod (it bills the GPU immediately)."
  exit 0
fi

# 4. Create. Never retried automatically: a request that may have arrived must not be sent twice.
out="$(api_post /pods "$body" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" >&2
  echo >&2
  api_auth_hint "$out" && exit 1
  case "$(printf '%s' "$out" | head -n1)" in
    "HTTP 400"*)
      # Only the "no capacity" answer is retryable. (Observed: "There are no longer any instances
      # available with the requested specifications.") Any other 400 is a rule violation.
      if printf '%s' "$out" | grep -qiE "instances available|no capacity|out of capacity"; then
        echo "There is no capacity for ${GPU_COUNT}x $GPU_ID in $DC right now. Nothing was created (see the message above). Try again later: scripts/wait-for-gpu.sh \"$GPU_ID\" $DC" >&2; exit 5
      fi
      echo "The API rejected the request (see the message above). Nothing was created." >&2; exit 1 ;;
    "HTTP 402"*) echo "Insufficient balance. Nothing was created." >&2; exit 1 ;;
    "HTTP 422"*) echo "The request body failed validation (see above). Nothing was created." >&2; exit 1 ;;
    "HTTP 429"*|"HTTP 5"*) echo "The API answered with a server error or is throttling. Whether a Pod was created is NOT certain: check scripts/v2-smoke.sh before retrying." >&2; exit 1 ;;
    "HTTP "*)    echo "Pod creation failed (see above)." >&2; exit 1 ;;
    *) echo "The connection failed while the request may already have been sent: the outcome is UNKNOWN and a Pod may exist (and bill). Check before retrying: scripts/v2-smoke.sh" >&2; exit 1 ;;
  esac
fi

new_id="$(printf '%s' "$out" | python3 -c 'import json,sys
try:
    p = json.load(sys.stdin); print(p.get("id", "") if isinstance(p, dict) else "")
except Exception:
    print("")')"
if [ -z "$new_id" ]; then
  echo "The request was accepted but the response had no Pod id. A Pod may exist and bill: check scripts/v2-smoke.sh" >&2
  exit 1
fi
echo
echo "Created Pod $new_id. It is billing now."
echo "Add this to your .env:  RUNPOD_POD_ID=$new_id"
echo
echo "Verifying (read-only) ..."
EXPECTED_VOLUME_ID="$VOLUME" "$HERE/verify-pod.sh" "$new_id" 9>&-   # fd 9 = the lock: not for children
vrc=$?
if [ "$vrc" -eq 0 ]; then
  echo
  echo "Next: set RUNPOD_POD_ID in .env (or rely on the active pool Pod), then scripts/wait-for-ready.sh and scripts/check-endpoint.sh (need VLLM_API_KEY)."
  exit 0
fi
if [ "$vrc" -ne 1 ]; then
  # The check could not run (the Pod could not be read even after retries): that is NOT evidence that the
  # Pod is wrong, so it is left alone.
  echo >&2
  echo "Pod $new_id was created and is RUNNING (billing), but it could NOT be verified (verify-pod.sh exit $vrc). I did not touch it." >&2
  echo "Check it now: scripts/verify-pod.sh $new_id   (stop or delete it if it is wrong: scripts/pod-terminate.sh --yes)" >&2
  exit 6
fi

# ---- verification FAILED: the Pod is wrong and billing. Clean up, every step retried.
# A signal from here on (for example start-any.sh forwarding a SIGTERM) must not interrupt the
# cleanup half-done: that could leave the Pod billing under its pool name, invisible to no guard
# but restartable by accident. Nothing below blocks for long, so this is a short-lived trap.
trap '' INT TERM HUP
echo >&2
echo "VERIFICATION FAILED: Pod $new_id is not what was intended, and it is billing." >&2
TRIES="${CLEANUP_TRIES:-3}"; DELAY="${CLEANUP_DELAY:-2}"
retry() {   # retry CMD...: up to TRIES attempts, DELAY seconds apart
  local i=1
  while :; do
    "$@" >/dev/null 2>&1 && return 0
    [ "$i" -lt "$TRIES" ] || return 1
    i=$((i + 1)); sleep "$DELAY" 8>&- 9>&-   # fd 8/9: never hold the lock through a sleep
  done
}
do_action() { retry api_post "/pods/$new_id/action" "{\"action\":\"$1\"}"; }
failed_name="failed-${POD_NAME}-${new_id}"
do_rename() { retry api_patch "/pods/$new_id" "$(FAILED_NAME="$failed_name" python3 -c 'import json,os; print(json.dumps({"name": os.environ["FAILED_NAME"]}))')"; }

stopped=0; renamed=0; terminated=0
if [ "$TERMINATE_ON_FAIL" -eq 1 ]; then
  do_action terminate && terminated=1
fi
if [ "$terminated" -eq 0 ]; then
  do_action stop && stopped=1          # ends the GPU billing
  if [ "$stopped" -eq 1 ]; then
    # Only rename after a CONFIRMED stop: a rename before that would take the Pod out of every
    # pool guard's sight while it keeps running and billing, and a second start-any.sh could then
    # create a duplicate right next to it.
    do_rename && renamed=1             # takes it out of the pool (the name no longer starts with the prefix)
  fi
  if [ "$stopped" -eq 0 ] || [ "$renamed" -eq 0 ]; then
    do_action terminate && terminated=1   # fallback: never leave a wrong Pod billing or restartable
  fi
fi
cmd="RUNPOD_POD_ID=$new_id scripts/pod-terminate.sh --yes"
if [ "$terminated" -eq 1 ]; then
  if [ "$TERMINATE_ON_FAIL" -eq 1 ]; then
    echo "It was TERMINATED (--terminate-on-fail); the Network Volume is untouched." >&2
  else
    echo "Stopping and renaming did not both work, so it was TERMINATED instead (stopped: $([ $stopped -eq 1 ] && echo yes || echo no), renamed: $([ $renamed -eq 1 ] && echo yes || echo no)). The Network Volume is untouched." >&2
  fi
elif [ "$stopped" -eq 1 ] && [ "$renamed" -eq 1 ]; then
  echo "It was STOPPED (billing ended) and renamed to '$failed_name', so it is no longer part of the pool. Inspect it, then remove it: $cmd" >&2
elif [ "$stopped" -eq 1 ]; then
  echo "It was stopped, but RENAMING AND TERMINATING FAILED: it still carries the pool name and could be restarted by start-any.sh. Run: $cmd" >&2
else
  echo "NOTHING WORKED (stop, rename, terminate): the Pod is STILL BILLING and still in the pool. Run: $cmd" >&2
fi
exit 1
