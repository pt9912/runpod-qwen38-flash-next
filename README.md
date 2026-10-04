# runpod-qwen38-flash-next

Bash tooling to run **Qwen3.8-Flash-Next (NVFP4)** with vLLM on **one NVIDIA B200** in RunPod Secure
Cloud: create, verify, start, stop and check a Pod through the RunPod REST API **v2**
(`https://api.runpod.io/v2`). Everything runs in a small Docker image through `make`.

The lifecycle scripts are derived from [pt9912/runpod-glm](https://github.com/pt9912/runpod-glm); the
serving image (`image/`) and the model recipe come from
[starkweatherdigital/qwen3.8-flash-next-nvfp4-recipe](https://github.com/starkweatherdigital/qwen3.8-flash-next-nvfp4-recipe).

## Status: not yet validated on a B200

- The 109 GB checkpoint `starkweatherdigital/qwen3.8-flash-next-nvfp4` was demonstrated upstream on a
  DGX Spark / GB10 (sm121), **not on a B200**. Nothing in this repo has been run on one yet.
- Upstream's prebuilt image (`jstarkg/vllm-gb10-flashnext`) is arm64/sm121 and cannot run on a B200;
  `create-pod.sh` refuses it. You build an x86_64 image from `image/` yourself.
- `image/` builds: patches 20/30/35/40/41 apply to the pinned amd64 base and the build's marker checks pass
  (vLLM `0.1.dev20073+g8e685d198`, torch 2.13.0+cu130). It has **never run on a GPU**: whether the NVFP4
  kernels work on a B200 is unknown until the first start.
- Whether the image serves the Anthropic-style `/v1/messages` (needed by `scripts/claude-qwen.sh`, which runs on your machine, not through make) is unverified.
- BF16 KV cache on purpose: the recipe reports that the QSA attention rejects an FP8 main KV cache.

## Quickstart

```bash
cp .env.example .env && $EDITOR .env      # RUNPOD_API_KEY, NETWORK_VOLUME_ID, VLLM_API_KEY, REMOTE_IMAGE
make precheck                             # local config + read-only API smoke test
make gpu                                  # B200 stock; copy the exact GPU id into .env (GPU_ID) if it differs
```

1. **Image:** a public build is on Docker Hub (`pt9912/vllm-qwen38-b200:1`); `.env.example` already pins its
   digest as `REMOTE_IMAGE`. To build your own instead, see `image/README.md`.
2. **Network Volume:** create one of **150 GB** (standard type) in a datacenter that has B200 stock
   (`make gpu`). The model is 109.23 GB (146 files, measured on Hugging Face) plus a few GB of vLLM cache;
   200 GB gives room for a second model revision or the mmap test. A volume can only be enlarged later,
   never shrunk, and it is billed (about $0.07/GB/month) even while the Pod is stopped. Put its ID in
   `NETWORK_VOLUME_ID`; Pods are always placed in the volume's datacenter.
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

## Serving profile (set as environment variables on the Pod, read by `image/serve-b200.sh`)

| Setting | Default | Notes |
|---|---|---|
| GPU | 1x B200, TP=1 | `GPU_ID` |
| Context | 131072 | `MAX_MODEL_LEN`; raise only after this is stable |
| KV cache | BF16 | no `--kv-cache-dtype fp8` |
| Prefix caching | on (`--mamba-cache-mode align`) | |
| Speculative decoding | native MTP, 1 token | |
| PLE mmap | **off** (`PLE_MMAP=0`) | `1` needs `MODEL=<local dir>`; B200 has the VRAM that mmap was meant to save, so leave it off first |
| Served name | `qwen3.8-flash-next` | |

The Pod overrides no command: the image entrypoint (`serve-b200`) builds the `vllm serve` line from
those variables, and `verify-pod.sh` checks them (and fails if a `cmd` override sneaks in).

## What differs from the GLM repo

B200 instead of B300, the Qwen model and profile above, env-driven serving through the image
entrypoint, a `REMOTE_IMAGE` that is required and must not be the arm64 image, and checks in
`verify-pod.sh` / `check-endpoint.sh` for the Qwen settings. The pool, lock, retry and cleanup logic is
unchanged. The tool image is the same minimal Alpine one; vLLM never runs in it.
