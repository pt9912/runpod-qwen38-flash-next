# Storage layout of the Pod, shared by create-pod.sh, verify-pod.sh, start-any.sh and pre-check.sh.
# Sourced, not run. Sets STORAGE, HF_HOME_DIR and VLLM_CACHE_DIR (or exits 2 on a bad STORAGE).
#
#   STORAGE=network  (default) the Network Volume holds the model and the caches, mounted at /workspace.
#                    The Pod is bound to the volume's datacenter.
#   STORAGE=global   a Global Volume (beta) holds only the model (MODEL=<local dir on it>); the caches
#                    stay on the container disk. Global Volumes have no file locking and no atomic
#                    rename, so nothing that writes (Hugging Face cache, vLLM compile cache) goes there.
#                    REST v1 and v2 cannot attach a Global Volume (checked 2026-10-04), so create-pod.sh creates
#                    such a Pod through GraphQL (podFindAndDeployOnDemand with volumeMounts of type
#                    OBJECT_STORE_VOLUME, as runpod-python does). GLOBAL_VOLUME_ID names the volume.
#   STORAGE=local    no volume at all: the Pod downloads the model from Hugging Face onto its container disk
#                    at every start (the image entrypoint does it, needs an image with PREFETCH_REPO support:
#                    image/serve-b200.sh) and the caches live there too. Measured: the 109 GB take 1.5 to 5
#                    minutes, far less than reading them from a Global Volume (about 30 minutes). Nothing is
#                    bound to a datacenter and nothing bills while no Pod runs. Needs a container disk of about
#                    200 GB (CONTAINER_DISK_GB, default 200 here) and the HF_TOKEN RunPod Secret.
#                    MODEL: a Hugging Face id (default) is downloaded to /models/<name>; an absolute path is used
#                    as the directory (the repo then comes from MODEL_REPO). MODEL_REVISION pins the commit.
#   HF_HOME_DIR / VLLM_CACHE_DIR   override the defaults below (HF_HUB_CACHE is HF_HOME_DIR/hub)
STORAGE="${STORAGE:-network}"
case "$STORAGE" in
  network)
    HF_HOME_DIR="${HF_HOME_DIR:-/workspace/huggingface}"
    VLLM_CACHE_DIR="${VLLM_CACHE_DIR:-/workspace/vllm-cache}"
    ;;
  global|local)
    HF_HOME_DIR="${HF_HOME_DIR:-/root/.cache/huggingface}"
    VLLM_CACHE_DIR="${VLLM_CACHE_DIR:-/root/.cache/vllm}"
    ;;
  *) echo "STORAGE must be 'network', 'global' or 'local' (is '$STORAGE')" >&2; exit 2 ;;
esac
case "$HF_HOME_DIR$VLLM_CACHE_DIR" in
  *[!A-Za-z0-9/._-]*) echo "HF_HOME_DIR and VLLM_CACHE_DIR must be plain absolute paths" >&2; exit 2 ;;
esac
case "$HF_HOME_DIR" in /*) ;; *) echo "HF_HOME_DIR must be an absolute path" >&2; exit 2 ;; esac
case "$VLLM_CACHE_DIR" in /*) ;; *) echo "VLLM_CACHE_DIR must be an absolute path" >&2; exit 2 ;; esac

# storage_resolve_model: for STORAGE=local sets MODEL (the directory in the Pod), PREFETCH_REPO and
# PREFETCH_REVISION from MODEL / MODEL_REPO / MODEL_REVISION; a no-op for the other modes. Call it once,
# right after sourcing, in every script that compares or builds the Pod's MODEL.
storage_resolve_model() {
  [ "$STORAGE" = local ] || return 0
  MODEL="${MODEL:-starkweatherdigital/qwen3.8-flash-next-nvfp4}"
  PREFETCH_REVISION="${MODEL_REVISION:-1b304e5f99de0faaf43c3a959f2b4000294bf65c}"
  case "$MODEL" in
    /*) PREFETCH_REPO="${MODEL_REPO:-starkweatherdigital/qwen3.8-flash-next-nvfp4}" ;;
    *)  PREFETCH_REPO="$MODEL"; MODEL="/models/${MODEL##*/}" ;;
  esac
  case "$PREFETCH_REPO$PREFETCH_REVISION$MODEL" in
    *[!A-Za-z0-9/._-]*) echo "MODEL, MODEL_REPO and MODEL_REVISION may only hold letters, digits and / . _ -" >&2; exit 2 ;;
  esac
  export MODEL PREFETCH_REPO PREFETCH_REVISION
}
