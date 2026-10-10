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
#   HF_HOME_DIR / VLLM_CACHE_DIR   override the defaults below (HF_HUB_CACHE is HF_HOME_DIR/hub)
STORAGE="${STORAGE:-network}"
case "$STORAGE" in
  network)
    HF_HOME_DIR="${HF_HOME_DIR:-/workspace/huggingface}"
    VLLM_CACHE_DIR="${VLLM_CACHE_DIR:-/workspace/vllm-cache}"
    ;;
  global)
    HF_HOME_DIR="${HF_HOME_DIR:-/root/.cache/huggingface}"
    VLLM_CACHE_DIR="${VLLM_CACHE_DIR:-/root/.cache/vllm}"
    ;;
  *) echo "STORAGE must be 'network' or 'global' (is '$STORAGE')" >&2; exit 2 ;;
esac
case "$HF_HOME_DIR$VLLM_CACHE_DIR" in
  *[!A-Za-z0-9/._-]*) echo "HF_HOME_DIR and VLLM_CACHE_DIR must be plain absolute paths" >&2; exit 2 ;;
esac
case "$HF_HOME_DIR" in /*) ;; *) echo "HF_HOME_DIR must be an absolute path" >&2; exit 2 ;; esac
case "$VLLM_CACHE_DIR" in /*) ;; *) echo "VLLM_CACHE_DIR must be an absolute path" >&2; exit 2 ;; esac
