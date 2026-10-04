#!/usr/bin/env bash
# Loads .env (bind-mounted read-only at /app/.env by the Makefile) before running the given
# command, the same way you would `set -a; source .env; set +a` locally. Never prints it.
#
# Precedence: an already-exported variable (for example a secret the Makefile forwarded with
# `-e VARNAME` because no .env file exists, e.g. in CI) wins over the SAME variable in .env.
# Without this, an .env that happens to exist (a stray file, a bad cache restore) would
# silently override what the caller explicitly exported, with no warning either way.
set -euo pipefail

if [ -e /app/.env ] && [ ! -f /app/.env ]; then
  # A directory here means the bind mount's source did not exist on the host (for example a
  # relative ENV_FILE override: Docker then creates an empty directory instead of failing).
  # Continuing would silently run with no secrets at all; refuse instead.
  echo "docker-entrypoint.sh: /app/.env exists but is not a regular file (a bad bind mount?); refusing to continue with no secrets loaded." >&2
  exit 1
fi

if [ -f /app/.env ]; then
  PASSTHROUGH_VARS="RUNPOD_API_KEY RUNPOD_BASE_URL RUNPOD_POD_ID NETWORK_VOLUME_ID VLLM_API_KEY QWEN_URL POOL_PREFIX POOL_MAX REMOTE_IMAGE MODEL MAX_MODEL_LEN GPU_MEMORY_UTILIZATION PLE_MMAP GPU_ID DATACENTER CONTAINER_DISK_GB VOLUME_SIZE_GB VOLUME_NAME"
  declare -A _pre=()
  for v in $PASSTHROUGH_VARS; do _pre[$v]="${!v:-}"; done
  set -a
  # shellcheck disable=SC1091
  source /app/.env
  set +a
  for v in $PASSTHROUGH_VARS; do
    [ -z "${_pre[$v]}" ] || export "$v=${_pre[$v]}"
  done
fi
exec "$@"
