# x86_64 vLLM image: Qwen3.8-Flash-Next NVFP4 on B200

Build context for the Pod image. It overlays the upstream recipe's patches on the vLLM base image and
installs `serve-b200` as the entrypoint (it reads `MODEL`, `SERVED_MODEL_NAME`, `CTX`, `GPU_MEM`,
`SEQS`, `MTP`, `CACHE`, `MMAP`, `PREWARM`, `TP` (tensor-parallel size, default 1),
`VLLM_EXTRA_ARGS` (appended last), which `create-pod.sh` sets on the Pod).

**Download at start (`PREFETCH_REPO`, new after `:3`).** If `PREFETCH_REPO` (a Hugging Face repo id) is set,
`serve-b200` first downloads that repo at `PREFETCH_REVISION` (default `main`) into the directory `MODEL`
(which must then be an absolute path), removes the download bookkeeping, and writes `.prefetch-complete`; a
directory that already has the marker is not downloaded again, and an interrupted download resumes. This is what
`STORAGE=local` in `create-pod.sh` uses (no volume; the 109 GB took 1.5 to 5 minutes on RunPod). The published
`:3` does not have it: build and push a new tag (for example `:4`) and pin its digest in `REMOTE_IMAGE`.
Tested with stubs, then run on a 1x H200 on 2026-10-10 (see `docs/startup-times.md`).

```bash
IMAGE=docker.io/YOU/vllm-qwen38-b200:1 ./build.sh
docker push docker.io/YOU/vllm-qwen38-b200:1      # then pin REMOTE_IMAGE by digest in ../.env
```

Newest build: `docker.io/pt9912/vllm-qwen38-b200:4`, digest
`sha256:f4ffbb29303c20fa0a473a89fb017a60f872b115a6a52ae99533111748210774` (linux/amd64, public, 19.9 GB): the same layers as `:3` plus `serve-b200` with the download at start
(`PREFETCH_REPO`, needed by `STORAGE=local`). Pushed 2026-10-10. Run on a 1x H200 (EUR-IS-4) the same day with `STORAGE=local`: it downloaded the model in
5 min 04 s and was ready 13 min 43 s after the Pod started; `make check` passed.

Previous build: `docker.io/pt9912/vllm-qwen38-b200:3`, digest
`sha256:26650509c7a5ae3196e6fa40463e96db67b2858c9a5f08867aa964195d3aa96f` (linux/amd64, public, 19.9 GB).
Built and import-tested on a CPU host only; never run on a GPU.

```bash
```

## Pins (defaults in `Dockerfile` and `build.sh`)

- `BASE_IMAGE`: `vllm/vllm-openai@sha256:0aea3024...`, the **linux/amd64** manifest of the tag
  `vllm/vllm-openai:qwen38-flash-next` (checked with `docker buildx imagetools inspect`: entrypoint
  `vllm serve`, CUDA 13.0.1, `TORCH_CUDA_ARCH_LIST` includes 10.0). The upstream recipe pins the arm64
  sibling of the same tag.
- `RECIPE_REF`: recipe commit `17c58984...` (2026-08-28).

## Patches

Applied: 20 (4-bit PLE loader), 30 (graph output buffer), 35 (PLE NVFP4 mmap), 40 (mamba eagle drop),
41 (mamba state seed). Skipped: 10 (an sm121 / DGX Spark Marlin thread-config workaround; a B200 should
not inherit it). The build checks marker strings and compiles the patched files, so a base that drifted
too far fails the build instead of at inference time.

The build succeeds (all five patches apply, marker checks pass). **Not yet run on a B200:** whether the
base's Marlin/NVFP4 kernels cover sm100 is unverified, so expect to iterate on the first start.

## PLE mmap

Leave `PLE_MMAP=0` for the first B200 test. With `1`, `MODEL` must be a local checkpoint directory
(download it to the Network Volume first); the mmap patch was designed for local NVMe, and a Network
Volume has different latency.
