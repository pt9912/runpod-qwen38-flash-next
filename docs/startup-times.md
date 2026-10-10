# Startup times

[Deutsch](startup-times.de.md) | English · [← Guide](guide.md)

How long a Pod takes from its start to answering requests, measured on RunPod with 1x H200 (Secure Cloud,
`PLE_MMAP=1`) on **2026-10-04** and **2026-10-10**. Every value is a **single observation** from vLLM's own
timestamps or from `make wait-ready`, not repeated. Times of 60 s or more are given in minutes and rounded
to whole seconds.

## Overview

| Variant | Time to ready | Clock starts at | Plan with | Remark |
|---|---|---|---|---|
| Network Volume, start 1 (warm host) | 5 min 26 s | vLLM's first log line | 10 to 16 min (all three) | the favourable case, probably files cached on that host |
| Network Volume, start 2 (cold host) | 15 min 58 s | vLLM's first log line | 10 to 16 min (all three) | main weights took 11 min 14 s |
| Network Volume, start 3 | 10 min 10 s | vLLM's first log line | 10 to 16 min (all three) | main weights took 8 min 1 s |
| No volume (`STORAGE=local`), new Pod | **13 min 43 s** | the Pod's `startedAt` | **about 14 min** | image pull about 3 min 45 s, download 5 min 4 s |
| No volume (`STORAGE=local`), restart of the stopped Pod | **8 min 57 s** | the Pod's `startedAt` | **about 9 min** | image already on the host, download 4 min 15 s |
| Global Volume | not completed | | | stopped at shard 40 of 133 after 12 min |

The clocks differ: the first three starts do not include pulling the Pod image onto the host and starting the
container (8.67 GB compressed, not measured), the two `STORAGE=local` starts do. Compare them with that in mind.

## Network Volume (2026-10-04, CA-MTL-3, model and caches on the volume)

| | Start 1 (warm host) | Start 2 (cold host) | Start 3 |
|---|---|---|---|
| Image | `:2` | `:2` (same Pod settings) | `:3` |
| Settings | validated deployment | as start 1, but `MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=6` | as start 2 |
| Pod | | new Pod on a host that had not just read the model | new Pod |
| vLLM's first log line to `Application startup complete` | **5 min 26 s** (08:09:31 to 08:14:57 UTC) | **15 min 58 s** (08:29:04 to 08:45:02 UTC) | **10 min 10 s** (09:00:39 to 09:10:49 UTC) |
| Loading the main weights | 1 min 50 s | 11 min 14 s | 8 min 1 s |
| Loading the MTP draft weights | 8.8 s | 1 min 45 s | 12.5 s |
| Model loading in total (vLLM's own figure) | 2 min 14 s | 13 min 15 s | not read |
| `torch.compile`, main model | 40.6 s | 30 s | 0.76 s |
| `torch.compile`, draft head | 8.2 s | 5 s | 4.2 s |
| FlashInfer autotune | 10.2 s (0 new configs saved) | not read | not read |
| CUDA graphs (main model, then draft and prefill) | a few seconds | not read | not read |

- **Start 1 only:** prewarming the 26.8 GiB PLE table into the page cache began at 08:11:36 UTC, the end was not logged
  separately. The first requests had a one-time Triton kernel JIT of about 6 s of extra latency (08:17:59 to 08:18:05 UTC).
- **Why the spread:** it comes almost entirely from reading the weights from the volume (1 min 50 s, 11 min 14 s,
  8 min 1 s). The cause, a cold read of about 100 GiB at roughly 150 MB/s, is an inference, not measured.
- **Start 3 compile times** are tiny because the compile cache on the volume was complete by then. The compile times of
  start 1 come from the first run with the mmap setting and probably include compiling.

## Without a volume (`STORAGE=local`, image `:4`)

2026-10-10, 1x H200 in EUR-IS-4, `MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=6`, 200 GB container disk, `HF_TOKEN`. The model is
downloaded from Hugging Face onto the container disk at every start.

| Phase | New Pod (`startedAt` 16:03:02 UTC) | Restart of the stopped Pod (`startedAt` 16:22:23 UTC) |
|---|---|---|
| `startedAt` to the first `Prefetch:` line (image pull and container start, not measured separately) | about 3 min 45 s | 3 s |
| Download of the 109.23 GB from Hugging Face onto the container disk | **5 min 4 s** (16:06:47 to 16:11:51) | **4 min 15 s** (16:22:26 to 16:26:41) |
| Prefetch done to vLLM's engine initialisation (Python and vLLM start) | about 52 s | not read |
| Loading the main weights from the local disk | 1 min 28 s | 1 min 29 s |
| Loading the MTP draft weights | 5.7 s | 5.7 s |
| Model loading in total (vLLM's own figure) | 1 min 46 s | 1 min 47 s |
| `torch.compile`, main model | 23.8 s | 23.5 s |
| `torch.compile`, draft head | 3.3 s | 3.3 s |
| FlashInfer autotune | about 6 s (0 configs saved) | not read |
| CUDA graphs | about 9 s | not read |
| vLLM's `init engine` in total (profile, KV cache, warm-up) | 1 min 27 s (compilation 27.1 s) | not read |
| `wait-ready`: first HTTP 200 (polls every 15 s) | **13 min 43 s** | **8 min 57 s** |

- **Restart:** the same Pod, 20 minutes later; its old machine was still free (`make stop`, then `make pod-start`). The container
  disk was **empty after the stop**, so the entrypoint downloaded the model again and the compile cache was gone too.
- **What a restart saves:** almost 5 minutes (4 min 46 s) against the new Pod, and that is almost entirely the image pull: the first
  `Prefetch:` line came 3 s after `startedAt` instead of 3 min 45 s, because the image was already on the host. A restart saves the
  pull, not the download.
- **KV cache and check:** the KV cache holds 1,690,023 tokens (concurrency 6.45 at 262,144 tokens). `make check` passed.

## Global Volume (2026-10-10, 1x H200 in US-NC-1)

| Step | Measured |
|---|---|
| vLLM loading the 133 shards from the volume: the first three | 25 s, 1 min 7 s and 54 s |
| vLLM loading the 133 shards: the following ones | 13 to 18 s each; vLLM estimated 24 to 29 min for the rest |
| Outcome | **stopped at shard 40 after 12 min**, so no complete start was timed |

## Downloads and copies

| Transfer | Time | Remark |
|---|---|---|
| Hugging Face to an empty Network Volume, download and load together | 4 min 7 s | 2026-10-04, CA-MTL-3, without mmap, `HF_XET_HIGH_PERFORMANCE=1`; vLLM reported `Model loading took 102.87 GiB memory and 247.17 seconds`. That Pod then failed on the KV cache (see the guide), so this is a measurement of download and load only, seen once |
| Hugging Face to a Pod's container disk, fill Pod for the Global Volume | 1 min 32 s and 4 min 48 s | 2026-10-10, two runs, with `HF_TOKEN` |
| Hugging Face to the container disk, serving Pod, new | 5 min 4 s | see above |
| Hugging Face to the container disk, serving Pod, restart | 4 min 15 s | see above |
| Container disk to the Global Volume (written, then verified file by file) | about 13 min | 2026-10-10 |

See the [guide](guide.md#local-storage-download-at-start) for what follows from these numbers.

## Limits of these numbers

- Every value is a single observation; the downloads from Hugging Face varied between 1 min 32 s and 5 min 4 s.
- The first three starts do not include the image pull and the container start. For the two `STORAGE=local` starts the pull is
  inferred from `startedAt` to the first `Prefetch:` line, not measured separately.
- Not measured: a `STORAGE=local` start with a warm compile cache (the cache is lost with the container disk). Start 3 above
  shows what a warm cache gives on the Network Volume.

## Measuring a start yourself

From the Pod's `startedAt`:

```bash
make start-when-free ARGS='1200 30' && make wait-ready
```

`wait-ready` polls `/v1/models` with your key every 15 s from the Pod's `startedAt` (via the API) until it
answers 200, prints the time and appends it to `.startup-times.log` (git-ignored). Run it together with
the start; if the Pod already answers on the first poll, nothing is logged.
