#!/usr/bin/env bash
set -euo pipefail

MODEL="${MODEL:-starkweatherdigital/qwen3.8-flash-next-nvfp4}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3.8-flash-next}"
PORT="${PORT:-8000}"
CTX="${CTX:-131072}"
GPU_MEM="${GPU_MEM:-0.90}"
SEQS="${SEQS:-16}"
MTP="${MTP:-1}"
CACHE="${CACHE:-1}"
MMAP="${MMAP:-0}"
PREWARM="${PREWARM:-0}"

export VLLM_PLE_NVFP4=1
export VLLM_PLE_NVFP4_MMAP="$MMAP"
export VLLM_PLE_NVFP4_MMAP_PREWARM="$PREWARM"

if [ "$MMAP" = 1 ] && [ ! -d "$MODEL" ]; then
  echo "MMAP=1 requires MODEL=/local/path/to/checkpoint." >&2
  exit 2
fi

args=(
 "$MODEL"
 --served-model-name "$SERVED_MODEL_NAME"
 --host 0.0.0.0 --port "$PORT"
 --tensor-parallel-size 1
 --quantization modelopt_fp4
 --gpu-memory-utilization "$GPU_MEM"
 --max-model-len "$CTX"
 --max-num-batched-tokens 8192
 --max-num-seqs "$SEQS"
 --reasoning-parser qwen3
 --enable-auto-tool-choice --tool-call-parser qwen3_coder
)

# Intentionally no --kv-cache-dtype fp8: this checkpoint/recipe requires
# the QSA main KV cache to remain BF16.
if [ "$CACHE" = 1 ]; then
  args+=(--enable-prefix-caching --mamba-cache-mode align)
else
  args+=(--no-enable-prefix-caching)
fi

if [ "$MTP" != 0 ]; then
  args+=(--speculative-config "{\"method\":\"qwen3_8_flash_next_mtp\",\"num_speculative_tokens\":$MTP}")
fi

if [ "$MMAP" = 1 ]; then
  SPLIT='["vllm::unified_attention_with_output","vllm::unified_mla_attention_with_output","vllm::mamba_mixer2","vllm::mamba_mixer","vllm::short_conv","vllm::qwen3_8_flash_next_ple_short_conv","vllm::qwen3_8_flash_next_qsa_with_output","vllm::linear_attention","vllm::qwen_gdn_attention_core","vllm::qwen_gdn_attention_core_fused_norm_packed","vllm::sparse_attn_indexer","vllm::ple_nvfp4_mmap_lookup"]'
  args+=(--compilation-config "{\"cudagraph_mode\":\"PIECEWISE\",\"cudagraph_capture_sizes\":[1,2,4,8,16],\"splitting_ops\":$SPLIT}")
fi

exec vllm serve "${args[@]}"
