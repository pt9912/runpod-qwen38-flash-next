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
TP="${TP:-1}"                       # tensor-parallel size = number of GPUs on the Pod
YARN_FACTOR="${YARN_FACTOR:-}"      # static YaRN factor (4.0 for 1M, 2.0 for 524288); empty = native 262144

export VLLM_PLE_NVFP4=1
export VLLM_PLE_NVFP4_MMAP="$MMAP"
export VLLM_PLE_NVFP4_MMAP_PREWARM="$PREWARM"

# Optional: fetch the checkpoint from Hugging Face into the local directory MODEL before serving (a Pod
# without a volume: measured on RunPod, the 109 GB take 1.5 to 5 minutes). Skipped when the directory is
# already complete (marker file), so a restart of the same container does not download again; an interrupted
# download resumes. MODEL must then be an absolute local path. HF_TOKEN, if set, is used by the hub library.
PREFETCH_REPO="${PREFETCH_REPO:-}"
PREFETCH_REVISION="${PREFETCH_REVISION:-main}"
if [ -n "$PREFETCH_REPO" ]; then
  case "$MODEL" in
    /?*) ;;
    *) echo "PREFETCH_REPO needs MODEL to be an absolute local directory (MODEL is '$MODEL')." >&2; exit 2 ;;
  esac
  if [ -f "$MODEL/.prefetch-complete" ]; then
    echo "Prefetch: $MODEL is already complete."
  else
    echo "Prefetch: downloading $PREFETCH_REPO @ $PREFETCH_REVISION to $MODEL ($(date -u +%H:%M:%S))"
    mkdir -p "$MODEL"
    export PREFETCH_REPO PREFETCH_REVISION MODEL
    python3 -c 'import os; from huggingface_hub import snapshot_download; snapshot_download(repo_id=os.environ["PREFETCH_REPO"], revision=os.environ["PREFETCH_REVISION"], local_dir=os.environ["MODEL"])' \
      || { echo "Prefetch FAILED: the download from Hugging Face did not finish (a restart of the Pod resumes it)." >&2; exit 1; }
    rm -rf "$MODEL/.cache"
    echo "$PREFETCH_REPO@$PREFETCH_REVISION $(date -u +%FT%TZ)" > "$MODEL/.prefetch-complete"
    echo "Prefetch: done ($(date -u +%H:%M:%S))."
  fi
fi

if [ "$MMAP" = 1 ] && [ "$TP" != 1 ]; then
  echo "Warning: MMAP=1 with TP=$TP is not validated (the mmap patch was tested on one GPU)." >&2
fi
if [ "$MMAP" = 1 ] && [ ! -d "$MODEL" ]; then
  echo "MMAP=1 requires MODEL=/local/path/to/checkpoint." >&2
  exit 2
fi

args=(
 "$MODEL"
 --served-model-name "$SERVED_MODEL_NAME"
 --host 0.0.0.0 --port "$PORT"
 --tensor-parallel-size "$TP"
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

# Static YaRN (model card): extends the context beyond the native 262144. Needs MAX_MODEL_LEN (CTX) above
# 262144. The card warns that static YaRN can hurt short texts, so it is only set when requested.
if [ -n "$YARN_FACTOR" ]; then
  export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
  args+=(--hf-overrides "{\"text_config\":{\"rope_parameters\":{\"rope_type\":\"yarn\",\"factor\":$YARN_FACTOR,\"original_max_position_embeddings\":262144,\"rope_theta\":10000000,\"partial_rotary_factor\":0.25,\"mrope_interleaved\":true,\"mrope_section\":[11,11,10]}}}")
fi

# Optional extra vLLM arguments (word-split on purpose), appended last so they can override.
if [ -n "${VLLM_EXTRA_ARGS:-}" ]; then
  read -r -a extra <<<"$VLLM_EXTRA_ARGS"
  args+=("${extra[@]}")
fi

# The model's chat template only accepts reasoning_effort xhigh (default), medium and low and raises an
# error for "high" or "max", which many clients send. Serve a patched copy that maps high/max to xhigh and
# minimal to low. If the template file or the expected line is not found, the model's own template is used.
tmpl_src=""
if [ -f "$MODEL/chat_template.jinja" ]; then
  tmpl_src="$MODEL/chat_template.jinja"
elif [ ! -d "$MODEL" ]; then
  tmpl_src="$(python3 -c "from huggingface_hub import hf_hub_download as d; print(d('$MODEL', 'chat_template.jinja'))" 2>/dev/null || true)"
fi
if [ -n "$tmpl_src" ] && [ -f "$tmpl_src" ]; then
  sed "s/^\(    {%- set resolved_reasoning_effort = reasoning_effort|default('xhigh') %}\)\$/\1\n    {%- if resolved_reasoning_effort in ('high', 'max') %}{%- set resolved_reasoning_effort = 'xhigh' %}{%- elif resolved_reasoning_effort == 'minimal' %}{%- set resolved_reasoning_effort = 'low' %}{%- endif %}/" "$tmpl_src" > /tmp/chat_template.patched.jinja
  if grep -q "in ('high', 'max')" /tmp/chat_template.patched.jinja; then
    args+=(--chat-template /tmp/chat_template.patched.jinja)
  else
    echo "Note: chat template line not found; using the model's own template (reasoning_effort high will be rejected)." >&2
  fi
fi

exec vllm serve "${args[@]}"
