# Minimal image for the RunPod-management scripts (bash + curl + python3 only). No compiled
# artifact goes into this repo, so there is no build stage here either: vLLM/Qwen never run in
# this image, only on the RunPod Pod itself; this image only talks to the RunPod REST API from
# outside. It does NOT include scripts/claude-qwen.sh's job (that execs the `claude` CLI on your
# machine and is meant to run there directly, not containerized); see README.md.
# Pinned by digest (not just the tag) and by exact package version, so a rebuild weeks later
# cannot silently pick up a different Alpine/Python point release or package build.
FROM python:3.13-alpine@sha256:79e7a9b9ff1cbceff819f856fb374477792a5967759d94df266de7b7b4120e6f

RUN apk add --no-cache bash=5.3.9-r1 curl=8.22.0-r0

WORKDIR /app
COPY scripts/ ./scripts/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh scripts/*.sh

ENTRYPOINT ["docker-entrypoint.sh"]
