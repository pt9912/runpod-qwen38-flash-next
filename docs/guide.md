# runpod-qwen38-flash-next — Guide

[Deutsch](guide.de.md) | English · [← README](../README.md) · [Startup times](startup-times.md)

The README has the quickstart. This guide covers everything else: the setup in detail, every script,
the settings, the day-to-day workflow, memory and context maths, and what goes wrong and why.

Everything that is marked **validated** was observed on a real Pod on 2026-10-04 (1x H200 SXM,
Secure Cloud, datacenter CA-MTL-3). Everything else is either derived from documentation or untested,
and says so.

## Contents

1. [Architecture](#architecture)
2. [Scripts at a glance](#scripts-at-a-glance)
3. [Secrets](#secrets)
4. [First time setup](#first-time-setup)
5. [Settings (`.env`)](#settings-env)
6. [Network Volume](#network-volume)
7. [Create, verify, check](#create-verify-check)
8. [Day to day: start, stop, terminate](#day-to-day-start-stop-terminate)
9. [Logs and troubleshooting](#logs-and-troubleshooting)
10. [Memory, context and concurrency](#memory-context-and-concurrency)
11. [GPUs and what was validated](#gpus-and-what-was-validated)
12. [Claude Code](#claude-code)
13. [The Pod pool](#the-pod-pool)
14. [Building your own image](#building-your-own-image)

## Architecture

```
your machine                         RunPod                         Docker Hub
─────────────                        ──────                         ──────────
make <target>  ──docker run──►  scripts/*.sh  ──REST v2──►  api.runpod.io/v2
(tools image: bash+curl+python3)                              │
                                                              ▼ creates / starts / stops
                                                   Pod (Secure Cloud, 1 GPU)
                                                   ├─ image  pt9912/vllm-qwen38-b200 ◄── pulled from Docker Hub
                                                   ├─ /workspace = Network Volume (model 109 GB, caches)
                                                   └─ port 8000/http  ──►  https://<pod>-8000.proxy.runpod.net
```

- **Tools image** (`Dockerfile`): Alpine with bash, curl and python3 only. It talks to the RunPod REST API
  **v2** (`https://api.runpod.io/v2`, overridable with `RUNPOD_BASE_URL`). vLLM never runs in it.
- **Pod image** (`image/`): the vLLM base image plus five patches from the upstream recipe, with
  `serve-b200` as its entrypoint. The Pod sets **no command**: the entrypoint builds the `vllm serve`
  line from environment variables (`MODEL`, `CTX`, `TP`, `SEQS`, `MMAP`, ...). `verify-pod.sh` fails if a
  `cmd` override appears.
- **Network Volume:** holds the 109.23 GB checkpoint under `/workspace/huggingface` and the compile and
  autotune caches under `/workspace/vllm-cache`. It survives Pod stop and terminate, and it is bound to one
  datacenter: **a Pod must run in the volume's datacenter**, and a GPU must be free there.
- **Endpoint:** vLLM on port 8000, protected by `VLLM_API_KEY`, reached through the RunPod HTTPS proxy.
  It serves the OpenAI API (`/v1/chat/completions`, `/v1/models`) and the Anthropic API (`/v1/messages`,
  `/v1/messages/count_tokens`). Only `/v1/*` needs the key; `/health`, `/metrics` and `/docs` are open by
  vLLM's design.

## Scripts at a glance

Run everything through `make`; it builds the tools image first and mounts `.env` read-only. Extra
arguments go in `ARGS`. A name with spaces needs inner quotes: `make gpu ARGS='"RTX PRO 6000"'`.

| Target | Script | What it does | Bills? |
|---|---|---|---|
| `make help` | – | lists all targets | no |
| `make precheck` | `pre-check.sh` | tools, `.env`, volume id; `ARGS=--online` adds one API call | no |
| `make smoke` | `v2-smoke.sh` | quick read of the v2 API (`GET /pods`) | no |
| `make gpu` | `gpu-availability.sh` | stock of a GPU, overall and per datacenter; exit 2 = none (make still exits 0) | no |
| `make wait-gpu` | `wait-for-gpu.sh` | polls the stock until the GPU is free; starts nothing | no |
| `make volume` | `create-volume.sh` | `--list`, or create a Network Volume (dry run unless `--yes`) | **volume** |
| `make create` | `create-pod.sh` | create a Pod (dry run unless `ARGS=--yes`) | **GPU** |
| `make verify` | `verify-pod.sh` | checks GPU, volume, ports, env against `.env` | no |
| `make check` | `check-endpoint.sh` | key protection, served model, context length | no |
| `make logs` | `pod-logs.sh` | live container/system logs (Ctrl-C to stop) | no |
| `make wait-ready` | `wait-for-ready.sh` | waits until vLLM answers, logs the startup time | no |
| `make stop` | `stop-any.sh` | stops every active pool Pod | ends GPU billing |
| `make pod-stop` | `pod-stop.sh` | stops the Pod `RUNPOD_POD_ID` | ends GPU billing |
| `make pod-terminate` | `pod-terminate.sh` | deletes a Pod for good (`ARGS='--yes [ID]'`) | ends it |
| `make start` | `start-any.sh` | starts a stopped pool Pod, else creates one | **GPU** |
| `make pod-start` | `pod-start.sh` | starts the stopped Pod `RUNPOD_POD_ID` | **GPU** |
| `make start-when-free` | `start-when-free.sh` | retries `pod-start` while its GPU is occupied | **GPU** |
| `make abort` | – | stops a stuck create/start container | no |
| – | `claude-qwen.sh` | runs Claude Code against the Pod (on your machine, not via make) | no |

Every target that could create or change something is a dry run by default or asks for `--yes`.
`make` itself only exits 0 or 2; the script's real exit code is written to `.make-exit-code.<target>`
(git-ignored). `make gpu` is the exception: "no stock" (script exit 2) is an answer, so make exits 0 and
the real code still lands in `.make-exit-code.gpu`.

## Secrets

| Secret | Where | Used for |
|---|---|---|
| `RUNPOD_API_KEY` | `.env` | all scripts. Reading works with a read-only key; create, start, stop and terminate need write access to Pods (else HTTP 403) |
| `VLLM_API_KEY` | `.env` **and** a RunPod Secret of the same name | the key vLLM enforces; the scripts and Claude Code send it |
| `HF_TOKEN` | RunPod Secret only | injected when you create with `--online`, for the model download |

The Pod references the RunPod Secrets as `{{ RUNPOD_SECRET_<name> }}`; no secret value is ever written
into the Pod definition or printed. `verify-pod.sh` fails if `VLLM_API_KEY` is a literal value instead of
a Secret reference. If a Secret does not exist, the placeholder stays unresolved: for `VLLM_API_KEY`,
`make check` then reports a 401 with your key; for `HF_TOKEN`, expect the download to be refused (not
tested). `.env` is git-ignored; never commit it.

## First time setup

1. `cp .env.example .env`, then set `RUNPOD_API_KEY` and `VLLM_API_KEY`. The `REMOTE_IMAGE` line already
   points at the published image.
2. In the RunPod console create the Secrets `VLLM_API_KEY` (same value) and `HF_TOKEN`.
3. `make precheck ARGS=--online` and `make smoke`: tools, `.env` and the API key.
4. Find a GPU: `make gpu ARGS='"NVIDIA H200"'` (or the card you want). Note a datacenter that has stock
   **and** supports Network Volumes.
5. Create the volume there: `make volume ARGS='--dc <DC>'` (dry run), then `--yes`. Put the printed id in
   `.env` as `NETWORK_VOLUME_ID`.
6. Set `GPU_ID`, `GPU_COUNT=1` and the other settings below.
7. First start on an empty volume: `make create` (dry run), then `make create ARGS='--yes --online'`. The
   model downloads onto the volume. Then watch `make logs`.
8. After the first start, switch to the offline settings (`PLE_MMAP=1` with the local model path, see
   "Settings") and use `make create ARGS=--yes` for later Pods.

## Settings (`.env`)

All optional unless marked. A value exported in your shell wins over the same name in `.env`.

| Variable | Default | Meaning |
|---|---|---|
| `RUNPOD_API_KEY` | – (required) | RunPod API key |
| `VLLM_API_KEY` | – (required) | key vLLM enforces; same value as the RunPod Secret |
| `NETWORK_VOLUME_ID` | – (required to create) | id of your Network Volume |
| `REMOTE_IMAGE` | – (required to create) | Pod image, ideally by digest. The arm64/sm121 DGX Spark image is refused |
| `RUNPOD_POD_ID` | – | fallback Pod for single-Pod scripts; the active pool Pod wins |
| `QWEN_URL` | – | endpoint URL if no Pod resolves (Claude Code, `wait-ready`) |
| `GPU_ID` | `NVIDIA B200` | exact id from `make gpu`. Quote it in `.env` if it has spaces |
| `GPU_COUNT` | `1` | GPUs per Pod; sets TP. **Keep 1** (see GPUs) |
| `DATACENTER` | volume's datacenter | where to place the Pod |
| `CONTAINER_DISK_GB` | `50` | container disk (the image is about 20 GB unpacked) |
| `MODEL` | `starkweatherdigital/qwen3.8-flash-next-nvfp4` | HF id, or a local directory (required with `PLE_MMAP=1`) |
| `MAX_MODEL_LEN` | `131072` | context per request; the model's limit is 262144 |
| `MAX_NUM_SEQS` | `16` | concurrent sequences (1 to 256) |
| `GPU_MEMORY_UTILIZATION` | `0.90` | vLLM's GPU memory share |
| `PLE_MMAP` | `0` | `1` serves the 26.8 GiB PLE table from disk; **required on 141 GB or less** |
| `VLLM_EXTRA_ARGS` | – | extra `vllm serve` arguments, word-split, appended last |
| `POOL_PREFIX` / `POOL_MAX` | `qwen3.8-flash-next` / `6` | the Pod pool, see below |
| `VOLUME_NAME` / `VOLUME_SIZE_GB` | `qwen3.8-flash-next` / `150` | defaults of `make volume` |

**The validated H200 setting** (volume in CA-MTL-3):

```
GPU_ID="NVIDIA H200"
GPU_COUNT=1
PLE_MMAP=1
MODEL=/workspace/huggingface/hub/models--starkweatherdigital--qwen3.8-flash-next-nvfp4/snapshots/1b304e5f99de0faaf43c3a959f2b4000294bf65c
```

The snapshot directory is the Hugging Face revision of the checkpoint (`main` was `1b304e5f…` on
2026-10-04). If the revision changes, the path no longer exists: list
`/workspace/huggingface/hub/models--…/snapshots/` on the volume. Pod settings are fixed when the Pod is
created; to change one, terminate the Pod and create a new one.

## Network Volume

- **Size:** 150 GB is the recommended minimum: the model is 109.23 GB (146 files, measured on Hugging
  Face; `du` on the volume showed 102 GiB) plus a few GB of caches. 200 GB leaves room for a second model
  revision. A volume can only be **enlarged**, never shrunk, and it cannot move to another datacenter.
- **Price:** about $0.07/GB/month (standard tier, under 1 TB; RunPod's published rate), billed hourly and
  also while no Pod runs. 150 GB is about $10.50 a month.
- **Create:** `make volume ARGS='--dc <DC>'` is a dry run and shows the request and the cost; add `--yes`
  to create. It checks that the datacenter exists and offers the tier, and refuses a second volume of the
  same name. Not every datacenter offers volumes (on 2026-10-04 EUR-IS-4, EUR-IS-5, US-GA-2 and US-NC-1
  did not; US-CA-2 offered only the high-performance tier). `make volume ARGS=--list` shows yours.
- **Delete:** not in this repo on purpose. Use the RunPod console. A volume bills until it is deleted.
- **One Pod at a time:** two Pods that share a volume share `/workspace/vllm-cache`; the pool guards
  refuse a second active pool Pod.

## Create, verify, check

```bash
make create                      # dry run: prints the request and the stock, creates nothing
make create ARGS='--yes'         # creates the Pod; GPU billing starts at once
make create ARGS='--yes --online'  # same, with downloads allowed (first start on an empty volume)
```

`create-pod.sh` options: `--yes`, `--online`, `--ssh` (also exposes 22/tcp; not verified for this image),
`--force` (a second pool Pod), `--terminate-on-fail`. It refuses a duplicate name and a second active pool
Pod, takes a host lock so two creates never run at once, **never retries a request that may have been
sent**, and then verifies the Pod. If verification fails, the Pod is stopped and renamed `failed-<name>-<id>`
(or terminated with `--terminate-on-fail`).

Exit codes: 0 done or verified, 1 failure, 2 bad arguments, 3 name exists or pool Pod active, 4 another
start in progress, 5 no capacity (nothing billed), 6 created but could not be verified (left running).

```bash
make verify        # GPU id and count, volume, port, env (MODEL, CTX, TP, SEQS, MMAP, ...), key as Secret
make check         # without key 401, with key 200, served model, context length, model root
make wait-ready    # wait until vLLM answers; appends the time to .startup-times.log
```

`verify` and `check` compare against your `.env`, so run them with the same `.env` you created with.

## Day to day: start, stop, terminate

- **Stop billing:** `make stop` (all active pool Pods). A stopped Pod releases the GPU and keeps its
  definition; the volume stays. `make pod-stop` does the same for `RUNPOD_POD_ID`.
- **Start again:** `make start` restarts a stopped pool Pod, or creates a new one. A restarted Pod runs on
  its **old machine** with its **old settings**; if that machine's GPU was taken meanwhile, the start is
  refused (exit 5, nothing billed) and `make start-when-free ARGS='1200 30'` retries it. Settings never
  change on a restart. To change them, terminate and create.
- **Delete a Pod:** `make pod-terminate ARGS='--yes <POD_ID>'`. The volume is not touched. The Pod name
  stays taken until the old Pod is gone, which blocks a new `make create` (exit 3).
- **Caches:** the vLLM compile cache, the FlashInfer autotune results and the model survive on the
  volume, so a later start skips the download and most of the compilation.

## Logs and troubleshooting

`make logs ARGS='--tail 200'` streams the container and system logs; add `--source container` to hide the
image-pull lines. Ctrl-C stops it (`docker ps --filter ancestor=runpod-qwen38-tools` finds a leftover
container). **After a failed start the Pod restarts vLLM in a loop and keeps billing.** Read the first
minutes of the log, and stop or terminate a Pod that failed.

| Symptom | Cause | What to do |
|---|---|---|
| `NotImplementedError: NVFP4 PLE supports TP=1 only` | `GPU_COUNT` 2 or more: patch 20's PLE loader supports one GPU only (seen on 2x RTX PRO 6000) | `GPU_COUNT=1` on a card with enough memory |
| `Available KV cache memory: -10.45 GiB`, then `No available memory for the cache blocks` | the weights (102.87 GiB) plus overhead do not fit a 141 GB card at 0.90 | `PLE_MMAP=1` with the local model path (frees about 27 GiB; seen on the H200) |
| `MMAP=1 requires MODEL=/local/path/...` | `MODEL` is a Hugging Face id | set `MODEL` to the snapshot directory on the volume |
| `A Pod named '...' already exists` (exit 3) | the old Pod still exists, even when stopped | terminate it (`make pod-terminate`) or set `POD_NAME` |
| `no capacity` (exit 5) | no GPU free in the volume's datacenter | `make wait-gpu`, then retry; nothing was billed |
| `make check`: with your key HTTP 401 | the Pod's `VLLM_API_KEY` Secret is missing or differs from `.env` | create the Secret with the same value, recreate the Pod |
| HTTP 403, body `error code: 1010`, from your own Python or other client | the RunPod proxy (Cloudflare) blocks the default Python User-Agent; `curl` is not blocked | set a different `User-Agent` header, for example `curl/8.5.0` |
| `unknown datacenter 'PRO'` from `make gpu` | a GPU name with spaces was split | quote it: `ARGS='"RTX PRO 6000"'` |
| `Datacenter X does not support Network Volumes` | not every datacenter has volumes | pick another (`make volume` checks first) |
| `Unknown vLLM environment variable VLLM_PLE_NVFP4*` | the variables belong to the patch, not to vLLM | harmless |
| `Triton kernel JIT compilation during inference` after the first requests | kernels compile once on first use | harmless, a one-time latency spike |
| Hopper: `FlashInfer GDN prefill is JIT-compiled` | the linear-attention prefill kernel compiles at warm-up | worked on the H200; if it fails, `VLLM_EXTRA_ARGS="--gdn-prefill-backend triton"` |
| `GPU does not have native support for FP4` (H200) | Hopper has no FP4 tensor cores; vLLM uses the Marlin weight-only backend | expected; compute-heavy loads may be slower |

## Memory, context and concurrency

All numbers are from the validated H200 run (141 GB card, `GPU_MEMORY_UTILIZATION=0.90`, `PLE_MMAP=1`).

| Quantity | Value |
|---|---|
| Model in GPU memory | 76.04 GiB (102.87 GiB without mmap) |
| KV cache | 46.75 GiB = **1,575,594 tokens** (about 33,700 tokens per GiB) |
| Concurrency at 131,072 tokens | 12.02x |
| Concurrency at 262,144 tokens, `MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=6` | **6.45x**: vLLM then reports 1,690,023 tokens for 46.76 GiB |

- The KV cache is a fixed pool of tokens shared by all requests. Keep `MAX_NUM_SEQS x MAX_MODEL_LEN` at or
  below the token count vLLM prints; vLLM prints the resulting `Maximum concurrency`.
- **6 sessions of the full native context** (`MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=6`): **validated to start**:
  the KV cache holds 1,690,023 tokens, 6.45x concurrency at 262,144, about 7 % reserve. The token count per GiB is
  not constant (33,700 at 131,072, 36,150 at 262,144); read the number vLLM prints rather than converting.
  Tested on it: 6 concurrent short requests (200 tokens each) all finished in 7.2 s (167 tokens/s together, about
  28 per stream, through the RunPod proxy), and a hidden code word in the middle of a synthetic text was
  found at 56,188 and at 170,671 prompt tokens (5.4 s and 13.5 s, about 12,000 prompt tokens/s). Long runs:
  one prompt of 254,572 tokens (97 % of the limit) returned both of two hidden keys (at 20 % and 80 %) in 21 s;
  **six simultaneous prompts of 248,177 tokens each** (1,489,060 tokens, 88 % of the KV cache, each with its own text
  and key position from 10 % to 90 %) all returned the right key, in 61 to 108 s each and 108 s in total (about
  13,800 prompt tokens/s). No error appeared in the filtered Pod log. **Not tested:** anything above the native
  262,144 (YaRN), reasoning over real documents, answer quality near the end of the context, concurrent
  long decoding. Finding one hidden key in synthetic repetitive text is an easy task; it shows that the cache,
  the scheduler and the long-context path work, not how well the model reasons over long inputs.
- **The model's limit is 262,144** (`max_position_embeddings`; rope type `default`, no scaling). More needs
  rope scaling. The official model card (`Qwen/Qwen3.8-Flash-Next`) says "262,144 natively and extensible up
  to 1,000,000 tokens" with **static YaRN** and gives the vLLM setting: `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1`,
  `--max-model-len 1000000` and `--hf-overrides` with `text_config.rope_parameters` = `rope_type yarn`,
  `factor 4.0` (2.0 for 524,288), `original_max_position_embeddings 262144`, `rope_theta 10000000`,
  `partial_rotary_factor 0.25`, `mrope_interleaved true`, `mrope_section [11,11,10]`. The card warns that static
  YaRN can hurt short texts, so set it only when needed. All variants share the 262,144 config; there is no
  separate 1M weight set (the "1M by default" Qwen3.8-Flash is Qwen's hosted product). **Untested here:** that
  setting with this NVFP4 build and the patches, the quality at 1M, and the prefill time.
- **What fits on the H200 at 33,700 tokens per GiB:** 1 x 1M session needs 29.7 GiB of the 46.75 GiB (fits),
  3 x 500k needs 44.5 GiB (fits tightly), 6 x 1M needs about 187 GiB (does not fit).
- The KV cache stays BF16: the recipe reports that the attention layers reject an FP8 main KV cache.
- Prefill speed for very long prompts was not measured. On Hopper the FP4 path is weight-only (Marlin),
  which is slower for compute-heavy work.

## GPUs and what was validated

| Setup | Result |
|---|---|
| 1x H200 SXM, CA-MTL-3, `PLE_MMAP=1` | **validated 2026-10-04**: starts, passes `make check`, answers chat and Anthropic-API requests (see below) |
| 1x H200 SXM without mmap | **fails**: KV cache would be −10.45 GiB |
| 2x RTX PRO 6000 (Blackwell, 96 GB each), TP=2 | **fails**: `PLE supports TP=1 only` |
| 1x RTX PRO 6000 with mmap | untested; about 80 GB of weights on 96 GB is tight |
| 1x B200 | the intended target; **never run**, none was in stock |

What the H200 run showed: the Marlin weight-only NVFP4 MoE backend works on Hopper; startup from vLLM's
first log line to ready took about 5.5 minutes with the model already on the volume; `make check` passed
all five checks; two short chat requests gave coherent German answers with the reasoning split out of the
content (the second ran at about 68 tokens/s end to end through the RunPod proxy; the first included
one-time Triton JIT). That is one Pod and two short requests, not a benchmark.

List prices seen in the RunPod console on 2026-10-04 (not read from the API): B200 6.79 $/h, H200 SXM
4.59 $/h, RTX PRO 6000 2.09 $/h, B300 7.89 $/h. Stock was "none" for the B200, "low" for the H200 SXM in
most datacenters.

## Claude Code

`scripts/claude-qwen.sh` runs on **your machine** and needs `claude` on the PATH:

```bash
set -a; source .env; set +a
scripts/claude-qwen.sh            # arguments go to claude
```

It resolves the single active pool Pod (else `RUNPOD_POD_ID`, else `QWEN_URL`), prints which and why,
waits for `/v1/models`, then sets `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` (your `VLLM_API_KEY`),
`CLAUDE_CODE_MAX_CONTEXT_TOKENS` (from `MAX_MODEL_LEN`) and the Haiku, Sonnet and Opus aliases (all
`qwen3.8-flash-next`, so background calls do not 404), then runs `claude --model qwen3.8-flash-next`. It
only reads; it never starts a Pod. Exit codes: 1 no Pod or never ready, 2 `VLLM_API_KEY` missing, 127 no
`claude`.

Checked against the H200 Pod: `POST /v1/messages` (a thinking block plus text), `POST
/v1/messages/count_tokens`, and a `tool_use` round trip all work; the script's Pod resolution and variables
were tested with a stand-in for `claude`. **Not tested:** a real interactive Claude Code session.

## The Pod pool

The pool is every Pod whose name starts with `POOL_PREFIX` (default `qwen3.8-flash-next`) and is not
terminated; it is read live, no ids are stored. `make start` and `make stop` work on the pool. New Pods get
unique names (`qwen3.8-flash-next`, `qwen3.8-flash-next-2`, ...), up to `POOL_MAX`.

- Two pool Pods never run at once (they would share `/workspace/vllm-cache` and bill twice): `create`,
  `start` and `pod-start` refuse it (exit 3 or 9) unless `--force`.
- `make start` first tries to restart the stopped pool Pods one after the other (a failed try costs
  nothing), and only creates a new one if none can start. `ARGS=--no-create` forbids creating,
  `ARGS=--dry-run` shows the plan, `ARGS=--wait` also runs `wait-ready`. A host lock allows one start or
  create at a time on your machine; a second one exits 4. `make abort` stops a stuck one.
- All Pods of a pool share one volume, so they all live in its datacenter.
- The start is not scheduled by this repo. The GLM repo this derives from has a GitHub Actions example
  for a daily start and stop; it was not carried over.

## Building your own image

`image/` has the build context; `image/README.md` has the pins. In short:

```bash
IMAGE=docker.io/YOU/vllm-qwen38-b200:3 image/build.sh
docker push docker.io/YOU/vllm-qwen38-b200:3        # then pin REMOTE_IMAGE by digest
```

The base is the linux/amd64 manifest of `vllm/vllm-openai:qwen38-flash-next`, pinned by digest. The recipe
commit is pinned too. The build applies patches 20, 30, 35, 40 and 41 and fails if their marker strings are
missing. Patch 10 (an sm121 Marlin workaround) is skipped on purpose. The published image is
`pt9912/vllm-qwen38-b200:2` (digest in `.env.example`).
