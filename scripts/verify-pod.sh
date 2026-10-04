#!/usr/bin/env bash
# Read-only check that a Pod matches what this repo intends. Run it right after
# `create-pod.sh` (or after a redeploy): a request can succeed while a field is silently
# dropped (for example the Network Volume), and then the Pod bills without the model on it.
# It prints only non-sensitive facts: env variable NAMES (never values), and for
# VLLM_API_KEY only whether it is a RunPod Secret reference.
#
# Usage: verify-pod.sh [POD_ID]
#   POD_ID              default: the single active pool Pod, else RUNPOD_POD_ID (the chosen Pod and why
#                       are printed)
#   EXPECTED_VOLUME_ID  default: NETWORK_VOLUME_ID (optional: without it the volume is not compared)
#   VERIFY_TRIES / VERIFY_DELAY   how often / how long apart the Pod is read (default 3 / 2 s)
# Exit codes: 0 = no FAIL (warnings allowed), 1 = at least one FAIL (the Pod is not what was intended),
#             2 = bad arguments, 6 = the Pod could not be read even after retries, or its response had
#             an unexpected shape: NOTHING was verified, which is not the same as "wrong" (create-pod.sh
#             leaves the Pod alone in that case).
set -uo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"
# shellcheck source=scripts/_pool.sh
source "$HERE/_pool.sh"

pool_resolve_pod "${1:-}"; rc=$?
if [ "$rc" -eq 2 ]; then
  echo "Several pool Pods are active; give the POD_ID:" >&2
  printf '%s' "$POOL_MEMBERS" | while IFS=$'\t' read -r i n st; do [ -z "$i" ] || printf '  %s  %s  %s\n' "$n" "$i" "$st" >&2; done
  exit 2
fi
[ "$rc" -eq 0 ] || { echo "Give a POD_ID, or set RUNPOD_POD_ID" >&2; exit 2; }
POD_ID="$RESOLVED_POD_ID"
case "$POD_ID" in *[!a-z0-9]*|"") echo "Invalid Pod ID '$POD_ID' (expected lower-case letters and digits)" >&2; exit 2 ;; esac
echo "Verifying Pod $POD_ID (source: $RESOLVED_SOURCE)"

VOLUME="${EXPECTED_VOLUME_ID:-${NETWORK_VOLUME_ID:-}}"

# Reading is safe to repeat: one network hiccup must not be read as "the Pod is wrong".
tries="${VERIFY_TRIES:-3}"; delay="${VERIFY_DELAY:-2}"; n=0
until resp="$(api_get "/pods/$POD_ID" 2>&1)"; do
  n=$((n + 1))
  if [ "$n" -ge "$tries" ]; then
    printf '%s\n' "$resp" >&2
    echo "Could not read Pod $POD_ID ($tries tries): NOTHING was verified." >&2
    exit 6
  fi
  sleep "$delay"
done

printf '%s' "$resp" | python3 -c '
import json, os, sys
pod_id, volume = sys.argv[1], sys.argv[2]
try:
    p = json.load(sys.stdin)
except Exception:
    p = None
if not isinstance(p, dict):
    print("[FAIL] the API returned no Pod object")
    sys.exit(1)

# Everything below only READS the parsed object; an unexpected shape (a field of a type this
# script does not expect) must not be read as "the Pod is wrong" (exit 1, which create-pod.sh
# would act on by stopping and renaming a possibly healthy Pod). It is instead "could not verify".
try:
  fails = 0
  def ok(m):   print("[ ok ] " + m)
  def warn(m): print("[WARN] " + m)
  def fail(m):
    global fails
    fails += 1
    print("[FAIL] " + m)

  print("Pod %s: %s, status %s, datacenter %s, $%s/h" % (pod_id, p.get("name", "?"), p.get("status", "?"), p.get("dataCenterId", "?"), p.get("cost", "?")))

  # GPU
  g = p.get("gpu") or {}
  want_gpu = os.environ.get("GPU_ID") or "NVIDIA B200"
  want_n = int(os.environ.get("GPU_COUNT") or "1")
  got_id = str(g.get("id", ""))
  id_ok = bool(got_id) and (want_gpu.lower() in got_id.lower() or got_id.lower() in want_gpu.lower())
  if g.get("count") == want_n and id_ok:
      ok("GPU: %dx %s" % (want_n, got_id))
  else:
      fail("GPU is %r x %r, expected %dx %r" % (g.get("count"), got_id, want_n, want_gpu))

  # Network Volume (the important one: a silently dropped volume means no model on the Pod)
  nets = ((p.get("mounts") or {}).get("network")) or []
  if not nets:
      fail("no Network Volume is mounted (mounts=%s): the model would be missing" % json.dumps(p.get("mounts")))
  else:
      n = nets[0]
      if n.get("path") != "/workspace":
          fail("Network Volume is mounted at %r, expected /workspace" % n.get("path"))
      elif volume and n.get("volumeId") != volume:
          fail("Network Volume is %r, expected %r" % (n.get("volumeId"), volume))
      else:
          ok("Network Volume %s mounted at /workspace%s" % (n.get("volumeId"), "" if volume else " (expected id unknown, not compared)"))

  # Ports
  ports = p.get("ports") or []
  (ok if "8000/http" in ports else fail)("ports: %s%s" % (", ".join(ports) or "none", "" if "8000/http" in ports else " (8000/http missing)"))

  # Env: names only. VLLM_API_KEY must be a Secret reference, never empty or a literal value.
  env = p.get("env") or {}
  print("       env variable names: %s" % ", ".join(sorted(env)))
  v = env.get("VLLM_API_KEY")
  if v is None or v == "":
      fail("VLLM_API_KEY is not set: the API would be unprotected")
  elif "RUNPOD_SECRET_" in v:
      ok("VLLM_API_KEY is a RunPod Secret reference")
  else:
      fail("VLLM_API_KEY holds a literal value, not a RunPod Secret reference (the key would be stored in the Pod definition)")
  if env.get("HF_HUB_OFFLINE") == "1" and "HF_TOKEN" in env:
      warn("HF_TOKEN is set although HF_HUB_OFFLINE=1 (not needed offline)")
  if env.get("HF_HOME") != "/workspace/huggingface" or env.get("VLLM_CACHE_ROOT") != "/workspace/vllm-cache":
      warn("HF_HOME / VLLM_CACHE_ROOT do not point to /workspace (caches would not persist)")

  # vLLM settings: the image entrypoint (serve-b200) reads them from the environment, so there is
  # no cmd to inspect. A set cmd would be an unintended override of that entrypoint.
  cmd = p.get("cmd")
  if cmd:
      fail("the Pod overrides the image command (cmd=%s): serve-b200 would not get its settings" % json.dumps(cmd))
  want_model = os.environ.get("MODEL") or "starkweatherdigital/qwen3.8-flash-next-nvfp4"
  want_ctx = os.environ.get("MAX_MODEL_LEN") or "131072"
  for key, want, level, what in (("MODEL", want_model, fail, "model"),
                                 ("SERVED_MODEL_NAME", "qwen3.8-flash-next", fail, "served model name"),
                                 ("CTX", want_ctx, fail, "context length"),
                                 ("SEQS", os.environ.get("MAX_NUM_SEQS") or "16", fail, "max concurrent sequences"),
                                 ("MTP", "1", warn, "MTP speculative decoding (1 token)"),
                                 ("CACHE", "1", warn, "prefix caching")):
      if env.get(key) == want:
          ok("env: %s=%s (%s)" % (key, want, what))
      else:
          level("env: %s is %r, expected %r (%s)" % (key, env.get(key), want, what))
  want_yarn = os.environ.get("YARN_FACTOR") or None
  if env.get("YARN_FACTOR") != want_yarn:
      fail("env: YARN_FACTOR is %r, expected %r (static YaRN factor)" % (env.get("YARN_FACTOR"), want_yarn))
  elif want_yarn:
      warn("YARN_FACTOR=%s: static YaRN is untested with this build and can hurt short texts" % want_yarn)
  if env.get("TP") != str(want_n):
      fail("env: TP is %r, expected %r (one tensor-parallel rank per GPU)" % (env.get("TP"), str(want_n)))
  want_cvd = ",".join(str(i) for i in range(want_n))
  if env.get("CUDA_VISIBLE_DEVICES") != want_cvd:
      fail("env: CUDA_VISIBLE_DEVICES is %r, expected %r" % (env.get("CUDA_VISIBLE_DEVICES"), want_cvd))
  if want_n > 1:
      warn("%d GPUs: tensor parallelism is not validated with this recipe (it was shown on a single GPU)" % want_n)
  if env.get("MMAP") == "1" and not str(env.get("MODEL", "")).startswith("/"):
      fail("MMAP=1 needs MODEL to be a local directory, but MODEL=%r: serve-b200 would exit" % env.get("MODEL"))
  if env.get("MMAP") == "1":
      warn("MMAP=1: not validated on B200 (upstream recipe was tested on GB10)")
  if "fp8" in json.dumps(env).lower() and "kv" in json.dumps(env).lower():
      fail("an FP8 KV cache setting is present: this model requires the BF16 main KV cache")

  print("Result: %s" % ("FAIL (%d)" % fails if fails else "no blocking problem"))
  sys.exit(1 if fails else 0)
except SystemExit:
  raise
except Exception as ex:
  print("[FAIL] verify-pod.sh could not check Pod %s (%r): the API response had an unexpected shape. Nothing was concluded." % (pod_id, ex), file=sys.stderr)
  sys.exit(6)
' "$POD_ID" "$VOLUME"
