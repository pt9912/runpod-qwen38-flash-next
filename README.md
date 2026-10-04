# runpod-qwen38-flash-next

Bash tooling to run **Qwen3.8-Flash-Next (NVFP4)** with vLLM on **one NVIDIA H200 SXM** (validated, see below) or another GPU in RunPod Secure
Cloud: create, verify, start, stop and check a Pod through the RunPod REST API **v2**
(`https://api.runpod.io/v2`). Everything runs in a small Docker image through `make`.

The lifecycle scripts are derived from [pt9912/runpod-glm](https://github.com/pt9912/runpod-glm); the
serving image (`image/`) and the model recipe come from
[starkweatherdigital/qwen3.8-flash-next-nvfp4-recipe](https://github.com/starkweatherdigital/qwen3.8-flash-next-nvfp4-recipe).

## Status

**Validated once, on 2026-10-04:** 1x **H200 SXM** (Secure Cloud, CA-MTL-3) with `PLE_MMAP=1`, image
`:2`. From vLLM start to `Application startup complete` it took about 5.5 minutes (08:09:31 to 08:14:57
UTC, after the image pull; the model was already on the volume): weights ~110 s, `torch.compile` ~50 s,
CUDA graphs, FlashInfer autotune. `make check`
passed all five checks and two short chat requests returned coherent German answers with the reasoning
split out (the second request ran at about 68 tokens/s end to end through the RunPod proxy; the first
included one-time Triton JIT warm-up). This is one pod and two short requests, not a benchmark.

What that run showed:

- **PLE mmap is required on a 141 GB card.** Without it the weights take 102.87 GiB and vLLM reports
  `Available KV cache memory: -10.45 GiB` and refuses to start. With `PLE_MMAP=1` the model takes
  76.04 GiB, leaving **46.75 GiB** of KV cache (1,575,594 tokens, 12x concurrency at 131,072 tokens each).
  `MMAP=1` needs `MODEL` to be a local directory: on the volume that is the HF cache snapshot, see below.
- **Hopper has no native FP4:** vLLM picks the Marlin weight-only NVFP4 MoE backend and warns that
  compute-heavy loads may be slower. It works.
- **Tensor parallelism does not work with this recipe:** with `GPU_COUNT=2` the loader stops with
  `NotImplementedError: NVFP4 PLE supports TP=1 only` (patch 20, `ple_layer.py`). 2x RTX PRO 6000 was
  tried and failed there. Use one card with enough memory.
- **A crashed Pod restarts vLLM in a loop and keeps billing.** Check the first minutes of `make logs` and
  stop or terminate a Pod that failed.

Still not done: a B200 run (none was in stock), a full interactive Claude Code session, long-context
tests, and any real benchmark. The 109 GB checkpoint was
demonstrated upstream on a DGX Spark / GB10 (sm121); upstream's prebuilt arm64 image
(`jstarkg/vllm-gb10-flashnext`) cannot run on x86 GPUs and `create-pod.sh` refuses it. BF16 KV cache on
purpose: the recipe reports that the QSA attention rejects an FP8 main KV cache.

### Known good `.env` for the H200 (volume in CA-MTL-3)

```
GPU_ID="NVIDIA H200"
GPU_COUNT=1
PLE_MMAP=1
MODEL=/workspace/huggingface/hub/models--starkweatherdigital--qwen3.8-flash-next-nvfp4/snapshots/1b304e5f99de0faaf43c3a959f2b4000294bf65c
```

The snapshot directory name is the Hugging Face revision of the checkpoint (`main` was `1b304e5f...` on
2026-10-04). The first start of a new volume needs `make create ARGS='--yes --online'` to download the
model with the default `MODEL` (no `PLE_MMAP`); then switch to the settings above for every later start.

## Quickstart

```bash
cp .env.example .env && $EDITOR .env      # RUNPOD_API_KEY, NETWORK_VOLUME_ID, VLLM_API_KEY, REMOTE_IMAGE
make precheck                             # local config + read-only API smoke test
make gpu                                  # B200 stock; copy the exact GPU id into .env (GPU_ID) if it differs
```

1. **Image:** a public build is on Docker Hub (`pt9912/vllm-qwen38-b200:2`); `.env.example` already pins its
   digest as `REMOTE_IMAGE`. To build your own instead, see `image/README.md`.
2. **Network Volume:** create one of **150 GB** (standard type) in a datacenter that has B200 stock
   (`make gpu`). The model is 109.23 GB (146 files, measured on Hugging Face) plus a few GB of vLLM cache;
   200 GB gives room for a second model revision or the mmap test. A volume can only be enlarged later,
   never shrunk, and it is billed (about $0.07/GB/month) even while the Pod is stopped. Put its ID in
   `NETWORK_VOLUME_ID`; Pods are always placed in the volume's datacenter. Or let the repo do it:
   ```bash
   make volume ARGS='--dc EU-RO-1'          # dry run: shows the request and the monthly cost
   make volume ARGS='--dc EU-RO-1 --yes'    # creates it (150 GB, STANDARD) and prints NETWORK_VOLUME_ID
   make volume ARGS=--list                  # your existing volumes
   ```
   It checks that the datacenter exists and supports the tier, and refuses a second volume of the same
   name. The volume is billed until you delete it (console or API); this repo has no delete command.
3. **Create a RunPod Secret** `VLLM_API_KEY` (the API key vLLM enforces) and, for the first download,
   a Secret `HF_TOKEN`. Put the same `VLLM_API_KEY` value in `.env`.
4. **Dry run, then create** (the Pod bills the GPU as soon as it exists):
   ```bash
   make create                      # prints the request, creates nothing
   make create ARGS='--yes --online'   # first time: --online lets vLLM download the 109 GB model onto the volume
   ```
   Later runs omit `--online` (offline mode, model and caches come from the Network Volume).
5. `make wait-ready`, `make check`, and when done `make stop`.

`make help` lists every target (`start`, `stop`, `terminate`, `logs`, `wait-gpu`, ...).

## Claude Code

`scripts/claude-qwen.sh` runs Claude Code against the Pod. It runs on **your machine** (not through
`make`) and needs `claude` on the PATH and `VLLM_API_KEY` in the environment:

```bash
set -a; source .env; set +a
scripts/claude-qwen.sh            # arguments are passed on to claude
```

It finds the single active pool Pod (else `RUNPOD_POD_ID`, else `QWEN_URL`), prints which one and why,
waits until `/v1/models` answers, then sets `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, the
context size (`MAX_MODEL_LEN`) and the model aliases and execs `claude --model qwen3.8-flash-next`. It only reads;
it never starts a Pod.

Checked on 2026-10-04 against the H200 Pod: the server answers the Anthropic API (`POST /v1/messages`
with a thinking block and text, `POST /v1/messages/count_tokens`, and a `tool_use` round trip), and the
script resolves the Pod and sets the variables correctly (tested with a stand-in for `claude`). Not tested:
a real interactive Claude Code session.

## Serving profile (set as environment variables on the Pod, read by `image/serve-b200.sh`)

| Setting | Default | Notes |
|---|---|---|
| GPU | 1x B200, TP=1 | `GPU_ID`, `GPU_COUNT` (keep it 1: TP>1 is not supported by the recipe); see "Other GPUs" |
| Context | 131072 | `MAX_MODEL_LEN`; raise only after this is stable |
| KV cache | BF16 | no `--kv-cache-dtype fp8` |
| Prefix caching | on (`--mamba-cache-mode align`) | |
| Speculative decoding | native MTP, 1 token | |
| PLE mmap | **off** (`PLE_MMAP=0`) | `1` needs `MODEL=<local dir>` and is **required on 141 GB or less** (validated on the H200); a 180 GB B200 may not need it |
| Served name | `qwen3.8-flash-next` | |

The Pod overrides no command: the image entrypoint (`serve-b200`) builds the `vllm serve` line from
those variables, and `verify-pod.sh` checks them (and fails if a `cmd` override sneaks in).

## Other GPUs

`GPU_ID` and `GPU_COUNT` in `.env` pick the card and how many of them one Pod gets. `GPU_COUNT=N` also sets
tensor parallelism N and `CUDA_VISIBLE_DEVICES=0..N-1` on the Pod; `verify-pod.sh` checks GPU id, count, `TP`
and the device list; `make gpu` / `make wait-gpu` report the stock of N GPUs on one machine. Use the exact id
RunPod reports (`make gpu ARGS='"RTX PRO 6000"'` lists matches; note the inner quotes for a name with spaces; there are workstation
variants with other ids). On 2026-10-04 `make gpu` showed `NVIDIA RTX PRO 6000 Blackwell Server Edition`.

| Setup | VRAM | List price seen in the console | Notes |
|---|---|---|---|
| 1x B200 | 180 GB | 6.79 $/h | the intended target; none free when last checked |
| 1x H200 SXM | 141 GB | 4.59 $/h | **validated** with `PLE_MMAP=1` (Marlin weight-only FP4 backend) |
| 2x RTX PRO 6000 | 2 x 96 GB | 2 x 2.09 $/h | **fails**: the PLE loader supports TP=1 only. One RTX PRO 6000 (96 GB) with `PLE_MMAP=1` is untested and tight (about 80 GB of weights) |

`GPU_COUNT>1` is wired through (TP and `CUDA_VISIBLE_DEVICES`), but this model cannot use it (see Status);
the option stays for other recipes. A card with NVLink-less PCIe would also need NCCL tuning. Prices are
the console's list prices from one screenshot, not read from the API.

## What differs from the GLM repo

B200 instead of B300, the Qwen model and profile above, env-driven serving through the image
entrypoint, a `REMOTE_IMAGE` that is required and must not be the arm64 image, and checks in
`verify-pod.sh` / `check-endpoint.sh` for the Qwen settings. The pool, lock, retry and cleanup logic is
unchanged. The tool image is the same minimal Alpine one; vLLM never runs in it.
