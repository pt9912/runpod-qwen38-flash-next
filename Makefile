# THE documented way to run this repo's scripts: `make <target>`, through the Docker image
# (Dockerfile). Do not call scripts/*.sh directly (except scripts/claude-qwen.sh, see below);
# only bash, curl and python3 go into the image, not onto your machine.
#
# .env, if present, is bind-mounted read-only into the container (never baked into the image,
# never printed) and sourced there; an already-exported variable still wins over the same name
# in .env (docker-entrypoint.sh). Without an .env file (for example in CI), the variables below
# are instead forwarded from whatever already exported them into this `make` invocation's
# environment (a GitHub Actions `env:` block, or `export RUNPOD_API_KEY=...` in your shell).
#
# wait-ready additionally bind-mounts .startup-times.log read-write: wait-for-ready.sh appends to
# it, and a `docker run --rm` container's own filesystem (and anything written to it) is discarded
# on exit, so without this mount the log would never survive past a single run.
#
# `make gpu` is the one exception to "make fails when the script fails": the script's exit 2 means
# "known GPU, no stock", which is an answer, not an error, so make exits 0 there (no "*** Error 2"
# noise). The real code (2) is still written to .make-exit-code.gpu, so `make gpu; cat
# .make-exit-code.gpu` tells "in stock" (0) from "none" (2). Real errors (1 API, 4 typo) still fail.
#
# Exit codes: GNU Make itself always exits 0 (success) or 2 (any recipe failure) -- verified, it
# does NOT preserve a recipe's actual exit code -- so the fine-grained codes documented in the
# README.md (5, 6, 8, 9, ...) are not visible in `$?` after a `make` invocation. Every target writes
# its real code to a PER-TARGET file, .make-exit-code.<target> (git-ignored), so scripting around
# `make` can still read it: `make check; rc=$$(cat .make-exit-code.check)`. Per-target, not one
# shared file: two DIFFERENT targets running at the same time (e.g. a monitoring loop's `make
# check` while a `make start` is still in progress) must not clobber each other's code (two
# invocations of the SAME target at once can still race the same file, but then both reflect the
# one real API state, not two different questions). `build` clears the file(s) for whatever
# target(s) were actually requested before it does anything else, so a build failure (the
# prerequisite of every target) is never mistaken for a stale previous success: the file is then
# simply absent rather than wrong.
#
# A container's own pool lock (_pool.sh) never spans two `docker run` invocations: each gets a
# fresh filesystem, so the lock file starts empty every time and would never actually block a
# second run. Anything that can START or CREATE a Pod (create, start, pod-start,
# start-when-free) is therefore serialized HERE, by a lock on the host, before it ever reaches
# the container: only one such target can run at a time; a second exits 99 with a message. Each
# of the four gets a fixed, predictable container name (runpod-qwen38-<target>) so a stuck one can
# be found and stopped: `make abort` (or `docker ps --filter name=^/runpod-qwen38-<target>$$` /
# `docker kill <name>` by hand). Prefer that over killing the `make`/`flock` process itself: Make
# does not forward signals to a recipe's children, so that can leave the container (and the lock)
# running; `docker kill` stops the container, which is what `docker run` (and therefore `flock`)
# is actually waiting on, so the lock is released correctly. Never delete LOCK_FILE by hand to
# "fix" a stuck lock: flock's lock belongs to the open file, not the path, so a fresh file at the
# same path lets a second create/start run immediately alongside a still-running first one --
# exactly the double-billing this lock exists to prevent. (LOCK_FILE lives under
# XDG_RUNTIME_DIR, like _pool.sh's own lock, not TMPDIR: unlike XDG_RUNTIME_DIR, TMPDIR is not
# guaranteed to be the same path across two shells of the same user on every OS, which would
# silently defeat this serialization.)
#
# Extra arguments: ARGS='...', e.g. `make gpu ARGS='B200 EU-NL-1'`.
IMAGE      := runpod-qwen38-tools
ENV_FILE   := $(CURDIR)/.env
ENV_MOUNT  := $(if $(wildcard $(ENV_FILE)),-v "$(ENV_FILE):/app/.env:ro",)
PASSTHROUGH := -e RUNPOD_API_KEY -e RUNPOD_BASE_URL -e RUNPOD_POD_ID -e NETWORK_VOLUME_ID \
               -e VLLM_API_KEY -e QWEN_URL -e POOL_PREFIX -e POOL_MAX \
               -e REMOTE_IMAGE -e MODEL -e MAX_MODEL_LEN -e GPU_MEMORY_UTILIZATION -e PLE_MMAP \
               -e GPU_ID -e DATACENTER -e CONTAINER_DISK_GB -e VOLUME_SIZE_GB -e VOLUME_NAME -e GPU_COUNT -e VLLM_EXTRA_ARGS -e MAX_NUM_SEQS -e YARN_FACTOR \
               -e STORAGE -e HF_HOME_DIR -e VLLM_CACHE_DIR
LOCK_FILE  := $(or $(XDG_RUNTIME_DIR),/tmp)/runpod-qwen38-make-$(shell id -u).lock
LOG_FILE   := $(CURDIR)/.startup-times.log
DOCKER_RUN_BASE := docker run --rm -i $(ENV_MOUNT) $(PASSTHROUGH)
DOCKER_RUN := $(DOCKER_RUN_BASE) $(IMAGE)
LOCKED     := flock -n -E 99 "$(LOCK_FILE)"

# CAPTURE NAME: append to any recipe line. Persists the real exit code (see the header) into
# .make-exit-code.NAME and re-raises it so make's own success/failure detection is unaffected.
CAPTURE = ; rc=$$?; echo "$$rc" > "$(CURDIR)/.make-exit-code.$(1)"; exit $$rc

.PHONY: help build precheck smoke gpu volume wait-gpu verify check logs wait-ready stop pod-stop pod-terminate \
        create start pod-start start-when-free abort

# Lists every target below that carries a trailing `## ...` comment, in the order they appear in
# this file (not alphabetically), so the grouping into read-only/single-Pod actions vs. the
# Pod-starting ones (see the comments above each block) stays visible. Bare `make` still runs
# `build` (the first target, i.e. the default goal) unchanged; run `make help` explicitly.
help: ## Show this list of targets
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# Clears the exit-code file(s) of whatever target(s) were actually requested (MAKECMDGOALS is
# the goal list from the command line, e.g. "create" for `make create ARGS=--yes`) before
# anything else: if the build itself fails below, make stops right here, so those files are
# simply gone rather than left holding a stale success code from an earlier, unrelated run.
build: ## Build the Docker image (a dependency of every target below, rarely called on its own)
	@for t in $(MAKECMDGOALS); do rm -f "$(CURDIR)/.make-exit-code.$$t"; done
	docker build -t $(IMAGE) .

# ---- read-only or single-Pod actions: never race a create/start, no host lock needed
precheck: build ## Check tools, environment and local files (ARGS=--online adds one read-only API call)
	$(DOCKER_RUN) bash scripts/pre-check.sh $(ARGS)$(call CAPTURE,precheck)
smoke: build ## Quick smoke test of the RunPod v2 API client
	$(DOCKER_RUN) bash scripts/v2-smoke.sh$(call CAPTURE,smoke)
gpu: build ## Show current GPU stock (ARGS='TYPE DATACENTER' to filter, e.g. ARGS='B200 EU-NL-1')
	$(DOCKER_RUN) bash scripts/gpu-availability.sh $(ARGS); rc=$$?; echo "$$rc" > "$(CURDIR)/.make-exit-code.gpu"; \
	  [ "$$rc" -ne 2 ] || exit 0; exit "$$rc"
volume: build ## Volumes: ARGS='--list' / ARGS='--dc EU-RO-1 [--yes]' (Network, 150 GB) / ARGS='--global [--list|--yes]' (Global, beta)
	$(DOCKER_RUN) bash scripts/create-volume.sh $(ARGS)$(call CAPTURE,volume)
wait-gpu: build ## Poll GPU stock until the requested GPU is available
	$(DOCKER_RUN) bash scripts/wait-for-gpu.sh $(ARGS)$(call CAPTURE,wait-gpu)
verify: build ## Check that a Pod matches what this repo intends
	$(DOCKER_RUN) bash scripts/verify-pod.sh $(ARGS)$(call CAPTURE,verify)
check: build ## Check a running Pod's endpoint: protected, serving the right model
	$(DOCKER_RUN) bash scripts/check-endpoint.sh $(ARGS)$(call CAPTURE,check)
logs: build ## Stream a Pod's container/system logs live (Ctrl-C to stop); ARGS='[POD_ID] [--source ...] [--tail N]'
	$(DOCKER_RUN) bash scripts/pod-logs.sh $(ARGS)$(call CAPTURE,logs)
wait-ready: build ## Wait until vLLM answers, measure and log the startup time
	@touch "$(LOG_FILE)"
	$(DOCKER_RUN_BASE) -v "$(LOG_FILE):/app/.startup-times.log" $(IMAGE) bash scripts/wait-for-ready.sh $(ARGS)$(call CAPTURE,wait-ready)
stop: build ## Stop every active pool Pod (ends GPU billing)
	$(DOCKER_RUN) bash scripts/stop-any.sh$(call CAPTURE,stop)
pod-stop: build ## Stop the Pod RUNPOD_POD_ID
	$(DOCKER_RUN) bash scripts/pod-stop.sh$(call CAPTURE,pod-stop)
pod-terminate: build ## Permanently delete the Pod RUNPOD_POD_ID (cannot be undone)
	$(DOCKER_RUN) bash scripts/pod-terminate.sh $(ARGS)$(call CAPTURE,pod-terminate)

# ---- these can START or CREATE a Pod (GPU billing): serialized on the host, named for `make abort`
create: build ## Create a new Pod (ARGS=--yes to actually create and bill the GPU; omit for a dry run)
	$(LOCKED) $(DOCKER_RUN_BASE) --name runpod-qwen38-create $(IMAGE) bash scripts/create-pod.sh $(ARGS); rc=$$?; \
	  [ "$$rc" -ne 99 ] || echo "Another create/start is already running on this machine. Find it: docker ps --filter name=runpod-qwen38-   Stop it: make abort" >&2; \
	  echo "$$rc" > "$(CURDIR)/.make-exit-code.create"; exit "$$rc"
start: build ## Start or create one pool Pod (ARGS=--wait to wait until ready)
	$(LOCKED) $(DOCKER_RUN_BASE) --name runpod-qwen38-start $(IMAGE) bash scripts/start-any.sh $(ARGS); rc=$$?; \
	  [ "$$rc" -ne 99 ] || echo "Another create/start is already running on this machine. Find it: docker ps --filter name=runpod-qwen38-   Stop it: make abort" >&2; \
	  echo "$$rc" > "$(CURDIR)/.make-exit-code.start"; exit "$$rc"
pod-start: build ## Start the stopped Pod RUNPOD_POD_ID
	$(LOCKED) $(DOCKER_RUN_BASE) --name runpod-qwen38-pod-start $(IMAGE) bash scripts/pod-start.sh $(ARGS); rc=$$?; \
	  [ "$$rc" -ne 99 ] || echo "Another create/start is already running on this machine. Find it: docker ps --filter name=runpod-qwen38-   Stop it: make abort" >&2; \
	  echo "$$rc" > "$(CURDIR)/.make-exit-code.pod-start"; exit "$$rc"
start-when-free: build ## Start the stopped Pod RUNPOD_POD_ID, retrying while its GPU is occupied
	$(LOCKED) $(DOCKER_RUN_BASE) --name runpod-qwen38-start-when-free $(IMAGE) bash scripts/start-when-free.sh $(ARGS); rc=$$?; \
	  [ "$$rc" -ne 99 ] || echo "Another create/start is already running on this machine. Find it: docker ps --filter name=runpod-qwen38-   Stop it: make abort" >&2; \
	  echo "$$rc" > "$(CURDIR)/.make-exit-code.start-when-free"; exit "$$rc"

# Finds whichever of the four named containers above is running (there is at most one, the host
# lock guarantees that) and stops it. The correct way to cancel a create/start; see the header.
abort: ## Stop a stuck create/start/pod-start/start-when-free container
	@cid="$$(docker ps -q --filter 'name=^/runpod-qwen38-(create|start|pod-start|start-when-free)$$')"; \
	if [ -z "$$cid" ]; then echo "Nothing to abort: no runpod-qwen38-* container is running."; exit 0; fi; \
	docker ps --filter "id=$$cid" --format 'Stopping: {{.Names}} ({{.ID}}), running for {{.RunningFor}}'; \
	docker kill $$cid >/dev/null
