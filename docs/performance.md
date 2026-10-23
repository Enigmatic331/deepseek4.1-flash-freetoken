# Production performance reference

Last reconciled: 2026-10-23

This page is the canonical memory aid for the performance of the accepted
DeepSeek V4.1 Flash profile on the qualified host. The numbers are measurements
on this particular machine, not portable promises for other systems.

## Profile under test

- checkpoint: `deepseek-ai/DeepSeek-V4.1-Flash-1017`
- model revision: `1bae0e1088993b9b82de08f59de5be5a34e42170`
- FreeToken revision: `5b0a6310e69fdc6752b79bf9b974b66b12347aae`
- topology: two RTX 5090s, one modified 48 GiB RTX 4090, and one modified
  32 GiB RTX 4080 SUPER
- context ceiling: 1,048,576 tokens
- scheduler prefill chunk: 8,192 tokens
- internal expert-route tile: 4,096 tokens
- main KV: exact packed E2M1 nibbles plus one E4M3 scale per 16 channels
- SWA: BF16
- admitted concurrency: at most two requests; the table below is single-stream
- DSpark/MTP: disabled

## How the figures are defined

All prefill rows below are cold and uncached: `new_tokens` equals the submitted
prompt size and `cached_tokens` is zero. Time to first token (TTFT) is measured
at the client. Effective prefill throughput is derived as:

```text
effective prefill tok/s = submitted prompt tokens / client TTFT seconds
```

This is whole-request throughput, including request and scheduler overhead. It
is not the speed of an individual attention kernel or scheduler chunk.

## Prefill versus submitted prompt size

| Submitted prompt | TTFT | Effective prefill | Observed scheduling | Gate |
| ---: | ---: | ---: | --- | --- |
| 4,096 tokens | 3.9054 s | **1,048.8 tok/s** | one 4,096-token batch | exact uncached output |
| 17,490 tokens | 9.7778 s | **1,788.7 tok/s** | 8,192 + 9,298 | exact uncached output |
| 40,000 tokens | 13.8911 s | **2,879.5 tok/s** | 8,192 x 4 + 7,232 | exact uncached output |
| 1,040,000 tokens | 361.061 s | **2,880.4 tok/s** | 127 prefill batches | three planted keys exact and ordered |

The 4K, 17.5K, and 40K rows each come from one accepted measured request after
a size-matched warmup. The near-ceiling row is one deliberately expensive
capacity-and-retrieval request. Treat the table as an operational curve, not a
statistical distribution.

The practical shorthand is:

- about **1.05K tok/s** for a 4K prompt;
- about **1.79K tok/s** around 17.5K;
- about **2.88K tok/s** from 40K through the measured 1.04M case.

## Why throughput depends on request size

The 8,192-token setting controls how work is scheduled; it does not imply a
fixed 8,192-token throughput. Short requests underfill the large matrix work and
pay fixed request, launch, routing, and synchronization costs over fewer tokens.
Larger prompts amortize those costs and keep the prefill kernels better occupied.

The 17,490-token case is also an awkward two-batch shape, while 40,000 tokens
contains four full 8,192-token batches and a substantial final batch. By 40K the
profile reaches its measured throughput plateau. DeepSeek V4.1 Flash's sparse
attention path keeps the accepted 1.04M request near the same aggregate rate;
that should not be generalized to models with dense full-context attention.

Consequently, do not quote one universal prefill speed for this deployment and
do not extrapolate the 1M rate down to interactive 4K prompts.

## Decode reference

Three stable single-stream short-context repetitions produced the same output
hash and averaged:

- **40.175 tok/s**;
- **24.891 ms/token**.

Decode uses the accepted trimmed inter-piece timing metric. This is a
single-stream, short-context service-tier result, not a strict per-request floor,
not aggregate C2 throughput, and not a measurement of sustained decode after a
1M-token prompt.

## Capacity, correctness, and health attached to the headline

The 1.04M gate planted keys at token depths 103,116, 519,480, and 935,843 and
returned all three exactly and in order. It used 8,126/8,192 main-KV pages,
finished normally, and released main KV and SWA to zero. Minimum authority free
VRAM was 2,288.62 MiB. Peak DIMM temperature was 59 C, with no thermal throttle,
OOM, CUDA error, service restart, Xid, AER, MCE, or EDAC event.

A faster result without the corresponding output, capacity, cache-cleanup, and
hardware gates is diagnostic rather than accepted production evidence.

## Interpretation boundaries

- Prefix-cache hits can make apparent prompt throughput much higher and are not
  comparable with this cold curve.
- C2 improves admission and interruption behavior; it does not promise that two
  simultaneous requests each retain the single-stream figures above.
- Prompt content, batch shape, thermal state, and competing traffic can move an
  individual result.
- Historical 512K and 786K reports used older runtime states or capacity
  profiles. Use them for engineering history, not as the current default.
- Cross-model comparisons require matched prompts, tokenization, cache state,
  context geometry, and timing definitions.

## Evidence

- [`qualification-20261021-packed-kv-1m.md`](qualification-20261021-packed-kv-1m.md)
- [`../results/production-performance-by-size.csv`](../results/production-performance-by-size.csv)
- [`../results/production-packed-kv-1m.csv`](../results/production-packed-kv-1m.csv)
