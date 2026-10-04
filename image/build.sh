#!/usr/bin/env bash
set -euo pipefail
IMAGE="${IMAGE:-qwen38-flash-next-b200:local}"
BASE_IMAGE="${BASE_IMAGE:-vllm/vllm-openai@sha256:0aea30240f3e3d9ffae8526643950e170eb5fa07fc427016a9dd90892afa2aa3}"
RECIPE_REF="${RECIPE_REF:-17c58984378af20fcec1f4ef3e96f244493d48e5}"
cd "$(dirname "$0")"
docker build --platform linux/amd64 \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  --build-arg RECIPE_REF="$RECIPE_REF" \
  -t "$IMAGE" .
