# x86_64 vLLM image: Qwen3.8-Flash-Next NVFP4 on B200

Build context for the Pod image. It overlays the upstream recipe's patches on the vLLM base image and
installs `serve-b200` as the entrypoint (it reads `MODEL`, `SERVED_MODEL_NAME`, `CTX`, `GPU_MEM`,
`SEQS`, `MTP`, `CACHE`, `MMAP`, `PREWARM`, which `create-pod.sh` sets on the Pod).

```bash
IMAGE=ghcr.io/YOU/vllm-qwen38-b200:1 ./build.sh
docker push ghcr.io/YOU/vllm-qwen38-b200:1      # then pin REMOTE_IMAGE by digest in ../.env
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

**Not yet built or run on a B200.** Expect to iterate on the first build and the first start.
Whether the base's Marlin/NVFP4 kernels cover sm100 is unverified.

## PLE mmap

Leave `PLE_MMAP=0` for the first B200 test. With `1`, `MODEL` must be a local checkpoint directory
(download it to the Network Volume first); the mmap patch was designed for local NVMe, and a Network
Volume has different latency.
