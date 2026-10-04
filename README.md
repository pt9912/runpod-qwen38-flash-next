# runpod-qwen38-flash-next

[Deutsch](README.de.md) | English · [Guide](docs/guide.md) · [Startup times](docs/startup-times.md)

Bash tooling to run **Qwen3.8-Flash-Next (NVFP4)** with vLLM on **one NVIDIA H200 SXM** (validated) or
another single GPU in RunPod Secure Cloud: create, verify, start, stop and check a Pod through the RunPod
REST API **v2** (`https://api.runpod.io/v2`). Everything runs in a small Docker image through `make`.

The lifecycle scripts are derived from [pt9912/runpod-glm](https://github.com/pt9912/runpod-glm); the
serving image (`image/`) and the model recipe come from
[starkweatherdigital/qwen3.8-flash-next-nvfp4-recipe](https://github.com/starkweatherdigital/qwen3.8-flash-next-nvfp4-recipe).
The [guide](docs/guide.md) has everything beyond this page.

## Status

**Validated once, on 2026-10-04:** 1x **H200 SXM** (Secure Cloud, CA-MTL-3) with `PLE_MMAP=1`, image `:2`.
From vLLM start to `Application startup complete` it took about 5.5 minutes (the model was already on the
volume). `make check` passed all five checks, and two short chat requests returned coherent German answers
with the reasoning split out. The Anthropic-style `/v1/messages`, `count_tokens` and a `tool_use` round
trip work too. This is one Pod and two short requests, not a benchmark.

What that run and the failed attempts showed:

- **PLE mmap is required on a 141 GB card.** Without it the weights take 102.87 GiB and vLLM reports
  `Available KV cache memory: -10.45 GiB` and refuses to start. With `PLE_MMAP=1` the model takes 76.04 GiB
  and leaves **46.75 GiB** of KV cache (1,575,594 tokens: 12x concurrency at 131,072 tokens, 6x at 262,144).
- **Hopper has no native FP4:** vLLM uses the Marlin weight-only NVFP4 backend. It works, but compute-heavy
  loads may be slower.
- **Tensor parallelism does not work with this recipe:** `GPU_COUNT=2` stops with
  `NotImplementedError: NVFP4 PLE supports TP=1 only`. 2x RTX PRO 6000 failed there. Use one card.
- **A crashed Pod restarts vLLM in a loop and keeps billing.** Check the first minutes of `make logs`.
- **The model's context limit is 262,144 tokens.** The model card documents YaRN scaling up to 1M tokens (see the guide); it is untested with this build.

Not done: a B200 run (none was in stock), a real interactive Claude Code session, long-context tests and
any real benchmark. The upstream arm64 image (`jstarkg/vllm-gb10-flashnext`) cannot run on x86 GPUs;
`create-pod.sh` refuses it. The KV cache stays BF16 on purpose (the recipe reports that the attention
layers reject FP8).

## Quickstart

```bash
cp .env.example .env && $EDITOR .env      # RUNPOD_API_KEY, VLLM_API_KEY; REMOTE_IMAGE is already set
make precheck ARGS=--online               # tools, .env, API key
make gpu ARGS='"NVIDIA H200"'             # stock per datacenter (quote names with spaces)
```

1. **Secrets:** in the RunPod console create `VLLM_API_KEY` (same value as in `.env`) and `HF_TOKEN`.
2. **Network Volume** (150 GB) in a datacenter that has stock and offers volumes:
   ```bash
   make volume ARGS='--dc CA-MTL-3'         # dry run: the request and the monthly cost (about $10.50)
   make volume ARGS='--dc CA-MTL-3 --yes'   # creates it and prints NETWORK_VOLUME_ID for .env
   ```
3. **First start** on the empty volume downloads the 109 GB model (`GPU_ID="NVIDIA H200"`, `GPU_COUNT=1`):
   ```bash
   make create                          # dry run: prints the request, creates nothing
   make create ARGS='--yes --online'    # creates the Pod; the GPU bills from now on
   make logs                            # follow the download and the vLLM start
   ```
4. **Later starts** use the model from the volume with `PLE_MMAP=1` (required on the H200). In `.env`:
   ```
   GPU_ID="NVIDIA H200"
   GPU_COUNT=1
   PLE_MMAP=1
   MODEL=/workspace/huggingface/hub/models--starkweatherdigital--qwen3.8-flash-next-nvfp4/snapshots/1b304e5f99de0faaf43c3a959f2b4000294bf65c
   ```
   then `make create ARGS=--yes`. The snapshot directory is the checkpoint's Hugging Face revision.
5. `make wait-ready`, `make check`, and when done `make stop` (the volume keeps model and caches).

Six sessions of the full native context: add `MAX_MODEL_LEN=262144` and `MAX_NUM_SEQS=6` (it fits with almost
no reserve; not yet run). `make help` lists every target.

## Claude Code

`scripts/claude-qwen.sh` runs Claude Code against the Pod, on **your machine** (not through `make`):

```bash
set -a; source .env; set +a
scripts/claude-qwen.sh            # arguments go to claude
```

It resolves the active Pod, waits for the endpoint and sets the Anthropic variables. It never starts a Pod.
Checked with a stand-in for `claude`; a real interactive session is untested. Details in the
[guide](docs/guide.md#claude-code).

## Documentation

| | |
|---|---|
| [docs/guide.md](docs/guide.md) | the full guide: architecture, every script, settings, volume, troubleshooting, memory maths |
| [docs/startup-times.md](docs/startup-times.md) | measured startup phases |
| [image/README.md](image/README.md) | the Pod image, its pins and patches |

## What differs from the GLM repo

The Qwen model and profile above instead of GLM on a B300, env-driven serving through the image entrypoint,
a required `REMOTE_IMAGE` that must not be the arm64 image, `make volume`, `GPU_ID`/`GPU_COUNT`/`MAX_NUM_SEQS`
settings, and checks in `verify-pod.sh` / `check-endpoint.sh` for the Qwen settings. The pool, lock, retry
and cleanup logic is unchanged. The tools image is the same minimal Alpine one; vLLM never runs in it.
