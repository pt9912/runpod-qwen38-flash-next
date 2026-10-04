# x86_64 vLLM image: Qwen3.8-Flash-Next NVFP4 on B200

Build context for the Pod image. It overlays the upstream recipe's patches on the vLLM base image and
installs `serve-b200` as the entrypoint (it reads `MODEL`, `SERVED_MODEL_NAME`, `CTX`, `GPU_MEM`,
`SEQS`, `MTP`, `CACHE`, `MMAP`, `PREWARM`, `TP` (tensor-parallel size, default 1),
`VLLM_EXTRA_ARGS` (appended last), which `create-pod.sh` sets on the Pod).

```bash
IMAGE=docker.io/YOU/vllm-qwen38-b200:1 ./build.sh
docker push docker.io/YOU/vllm-qwen38-b200:1      # then pin REMOTE_IMAGE by digest in ../.env
```

Published build: `docker.io/pt9912/vllm-qwen38-b200:2`, digest
`sha256:4e892eef3984225001df1f57a9e7080fecd3b870469c309d9b307f3772545f76` (linux/amd64, public, 19.9 GB).
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
