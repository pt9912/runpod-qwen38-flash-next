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
