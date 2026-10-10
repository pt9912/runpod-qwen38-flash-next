# Startup times

[Deutsch](startup-times.de.md) | English · [← Guide](guide.md)

Values read from the container log of the validated deployment on **2026-10-04** (1x H200 SXM, Secure
Cloud, CA-MTL-3, image `:2`, `PLE_MMAP=1`, model and caches already on the Network Volume). They are
**single observations** from vLLM's own timestamps, not produced by this repo's scripts and not repeated:

| Phase | Time |
|---|---|
| Loading the main weights | 110.0 s |
| Loading the MTP draft weights | 8.8 s |
| Model loading in total (vLLM's own figure) | 133.6 s |
| Prewarming the 26.8 GiB PLE table into the page cache | started 08:11:36 UTC; the end was not logged separately |
| `torch.compile`, main model | 40.6 s |
| `torch.compile`, draft head | 8.2 s |
| FlashInfer autotune | 10.2 s (0 new configs saved) |
| CUDA graphs (main model, then draft and prefill) | a few seconds |
| **vLLM's first log line to `Application startup complete`** | **5 min 26 s (326 s)**, 08:09:31 to 08:14:57 UTC |
| First requests: one-time Triton kernel JIT | about 6 s of extra latency (08:17:59 to 08:18:05 UTC) |

**A cold start, observed on the same day** (same Pod settings but `MAX_MODEL_LEN=262144` and `MAX_NUM_SEQS=6`, a
new Pod on a host that had not just read the model): vLLM's first log line to `Application startup complete`
took **15 min 58 s (958 s)**, 08:29:04 to 08:45:02 UTC. Loading the main weights took **674 s** and the draft
weights 105 s (vLLM's total for model loading: 795 s), against 110 s and 9 s in the table above; the compile
steps were 30 s and 5 s. The weights come from the Network Volume, so the 5.5 minutes above are the
favourable case (probably files cached on that host); plan for **a quarter of an hour** after a Pod has
been created or moved. The cause (cold read of about 100 GiB at roughly 150 MB/s) is an inference, not measured.

**A third start** (new Pod with image `:3`, same settings, 2026-10-04): vLLM's first log line 09:00:39 to `Application
startup complete` 09:10:49 UTC, **10 min 10 s (610 s)**. Loading the main weights took 481 s and the draft weights 12.5 s;
`torch.compile` took only 0.76 s and 4.2 s, because the compile cache on the volume was complete by then. The three starts so
far: 5 min 26 s, 15 min 58 s and 10 min 10 s. The spread comes almost entirely from reading the weights from the volume
(110 s, 674 s, 481 s), so treat **10 to 16 minutes** as the realistic range for a new Pod.

**From a Global Volume and from Hugging Face** (2026-10-10, single observations, H200 in US-NC-1, `PLE_MMAP=1`):
vLLM loading the 133 shards from a Global Volume took 13 to 18 s each after a slow start (25, 67 and 54 s for the
first three), with vLLM estimating 24 to 29 minutes for the rest; it was **stopped at shard 40 after 12 minutes**, so
no complete start was timed. Downloading the 109.23 GB from Hugging Face onto a Pod's container disk (with `HF_TOKEN`)
took **1 min 32 s** and **4 min 48 s** on two runs, copying them onto the Global Volume about 13 minutes. See the
[guide](guide.md#local-storage-download-at-start) for what follows from this.

**Without a volume (`STORAGE=local`, image `:4`)** (2026-10-10, 1x H200 in EUR-IS-4, `PLE_MMAP=1`,
`MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=6`, 200 GB container disk, `HF_TOKEN`; **one observation**, a new Pod with
everything cold). `make wait-ready`: **READY after 13 min 43 s (823 s)** from the Pod's `startedAt` (16:03:02 UTC).

| Phase | Time |
|---|---|
| `startedAt` to the first `Prefetch:` line (image pull and container start, not measured separately) | about 3 min 45 s (16:03:02 to 16:06:47) |
| Download of the 109.23 GB from Hugging Face onto the container disk | **5 min 04 s** (16:06:47 to 16:11:51) |
| Prefetch done to vLLM's engine initialisation (Python and vLLM start) | about 52 s (to 16:12:43) |
| Loading the main weights from the local disk | 88.3 s |
| Loading the MTP draft weights | 5.7 s |
| Model loading in total (vLLM's own figure) | 106.4 s |
| `torch.compile`, main model and draft head (cold cache on a new container disk) | 23.8 s and 3.3 s |
| FlashInfer autotune | about 6 s (0 configs saved) |
| CUDA graphs | about 9 s |
| vLLM's `init engine` in total (profile, KV cache, warm-up) | 86.9 s (compilation 27.1 s) |
| `wait-ready` first HTTP 200 (polls every 15 s) | 823 s after `startedAt` |

The KV cache holds 1,690,023 tokens (concurrency 6.45 at 262,144 tokens). `make check` passed. For comparison, the
three starts from a Network Volume took 5 min 26 s, 15 min 58 s and 10 min 10 s, and vLLM stopped at shard 40 of 133
after 12 minutes when loading from a Global Volume. Every start of this variant downloads again (the container disk
does not survive the Pod), so this is the number to plan with: about **14 minutes**, of which the download is about 5 and
the image pull about 4. The time from Hugging Face varied between 1.5 and 5 minutes in the earlier tests.

**Restart of the stopped Pod** (same Pod, 20 minutes later, its old machine was still free; `make stop`, then
`make pod-start`; one observation): **READY after 8 min 57 s (537 s)** from the new `startedAt` (16:22:23 UTC).
The container disk was **empty after the stop**: the entrypoint downloaded the model again (**4 min 15 s**, 16:22:26 to
16:26:41), then vLLM loaded the main weights in 89.1 s (draft 5.7 s, 107.0 s in total), `torch.compile` took 23.5 s and
3.3 s again (the compile cache was gone too). The 4 minutes less than the first start (13:43) are almost entirely the
image pull: the first `Prefetch:` line came 3 s after `startedAt` instead of 3 min 45 s, because the image was already
on the host. So a restart saves the pull, not the download.

**What is not in these numbers:** pulling the Pod image (8.67 GB compressed) onto the host and starting
the container, which happens before vLLM's first log line. It was not measured: the clock above starts at
vLLM's first log line, not at the Pod's `startedAt`. Also not measured: a restart of a stopped Pod on its
old machine, and a start with a warm compile cache. The compile times above come from the first run that
used the mmap setting, so they probably include compiling; a repeat start should skip most of it.

**The first start of an empty volume** also downloads the 109 GB model. On 2026-10-04, in CA-MTL-3 and
without mmap, vLLM reported `Model loading took 102.87 GiB memory and 247.17 seconds` for the download and
the load together, with `HF_XET_HIGH_PERFORMANCE=1`. That Pod then failed on the KV cache (see the guide),
so this is a measurement of the download and load only, seen once.

To measure a full start yourself, from the Pod's `startedAt`:

```bash
make start-when-free ARGS='1200 30' && make wait-ready
```

`wait-ready` polls `/v1/models` with your key every 15 s from the Pod's `startedAt` (via the API) until it
answers 200, prints the time and appends it to `.startup-times.log` (git-ignored). Run it together with
the start; if the Pod already answers on the first poll, nothing is logged.
