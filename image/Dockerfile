# syntax=docker/dockerfile:1
# Qwen3.8-Flash-Next 109GB NVFP4 overlay for linux/amd64 NVIDIA B200.
#
# BASE_IMAGE: the linux/amd64 manifest of the tag vllm/vllm-openai:qwen38-flash-next (the upstream
# recipe pins the arm64 sibling of the same tag, sha256:3b0e188f..., for the DGX Spark). Its
# TORCH_CUDA_ARCH_LIST contains 10.0 (B200 is sm100). Not yet run on a B200.
ARG BASE_IMAGE=vllm/vllm-openai@sha256:0aea30240f3e3d9ffae8526643950e170eb5fa07fc427016a9dd90892afa2aa3
FROM ${BASE_IMAGE}

USER root
ARG RECIPE_REF=17c58984378af20fcec1f4ef3e96f244493d48e5
RUN apt-get update \
 && apt-get install -y --no-install-recommends git patch ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Pull the upstream patch recipe at build time, pinned to a commit SHA.
RUN set -eux; \
    git clone --filter=blob:none --no-checkout \
      https://github.com/starkweatherdigital/qwen3.8-flash-next-nvfp4-recipe.git \
      /opt/qwen38-recipe; \
    cd /opt/qwen38-recipe; \
    git checkout "$RECIPE_REF"; \
    git rev-parse HEAD > /opt/QWEN38_RECIPE_COMMIT

# Apply only the hardware-independent PLE/prefix-cache patches.
# 10-sm121-marlin-thread-config.patch is deliberately skipped: B200 != SM121.
RUN set -eux; \
    PKG="$(python3 -c 'import os,vllm; print(os.path.dirname(os.path.dirname(vllm.__file__)))')"; \
    cd "$PKG"; \
    for p in \
      /opt/qwen38-recipe/patches/20-ple-4bit-loader.patch \
      /opt/qwen38-recipe/patches/30-ple-graph-output-buffer.patch \
      /opt/qwen38-recipe/patches/35-ple-nvfp4-mmap.patch \
      /opt/qwen38-recipe/patches/40-mamba-eagle-drop.patch \
      /opt/qwen38-recipe/patches/41-mamba-state-seed.patch; \
    do \
      echo "Applying $p"; patch -p1 --forward < "$p"; \
    done; \
    python3 - <<'PY'
import ast, os, py_compile, vllm
pkg=os.path.dirname(vllm.__file__)
checks=[
 ("models/qwen3_8_flash_next/nvidia/ple_layer.py",
  ["BCN76_PLE_NVFP4","BCN79_PLE_GRAPH","BCN82_PLE_NVFP4_MMAP"]),
 ("models/qwen3_8_flash_next/nvidia/ple_nvfp4_mmap.py",
  ["MmapNvFp4PleTable","ple_nvfp4_mmap_lookup"]),
 ("v1/core/single_type_kv_cache_manager.py",["BCN81_EAGLE_DROP"]),
 ("v1/worker/gpu/model_states/mamba_hybrid.py",["BCN81_STATE_SEED"]),
]
for rel, markers in checks:
    path=os.path.join(pkg,rel)
    src=open(path,encoding="utf-8").read()
    ast.parse(src); py_compile.compile(path,doraise=True)
    for m in markers: assert m in src, f"{m} missing from {path}"
    print("OK:",rel)
print("B200 overlay verification OK")
PY

COPY serve-b200.sh /usr/local/bin/serve-b200
RUN chmod +x /usr/local/bin/serve-b200 \
 && rm -rf /opt/qwen38-recipe/.git

ENTRYPOINT ["/usr/local/bin/serve-b200"]
