# Final EP4/C2 production qualification

Date: 2026-10-16

## Accepted outcome

FreeToken revision `2e5eaf5f96d795af21512c54140ffa5263bfb86d` is the
consolidated DeepSeek-V4.1-Flash production lineage. It runs native checkpoint
quantization and BF16 KV over four heterogeneous text ranks, advertises 786,432
tokens, admits at most two requests, and keeps DSpark/MTP off.

The final change overlaps token-boundary metadata preparation with the in-flight
forward. It changes scheduling/metadata timing, not model arithmetic.

## Final-profile geometry

- GPUs: two RTX 5090s, modified 48 GiB RTX 4090, modified 32 GiB RTX 4080 SUPER
- decode ownership: 32 / 144 / 144 / 64
- prefill ownership: 112 / 128 / 112 / 32
- cache slots: 240 / 1,536 / 2,350 / 1,408
- context: 786,432; full KV pages: 6,144; physical SWA pages: 1,152
- chunk/tile: 8,192 / 4,096 tokens
- C2: maximum two requests with one resident decode step between prefill chunks
- CPU assistance: two 24-thread pools on ranks 1/2
- native vision: rank 3's 4080 SUPER
- MoE hot-path statistics: off; cache reporting: on

## Performance result

| Metric | Authority-fusion control | Token-boundary candidate |
| --- | ---: | ---: |
| Sustained samples | 5 | 7 |
| Median decode | 35.349 tok/s | 35.875 tok/s |
| Median time/token | 28.289 ms | 27.874 ms |
| Median sustained TTFT | 1.2854 s | 1.2855 s |
| Change | — | +1.487% decode |

One candidate sample fell to 33.394 tok/s; the other six were 35.812–35.923
tok/s. The accepted median is therefore not a per-request minimum. A permanent
production exact smoke measured 35.731 tok/s. The matched 17,490-token cold
prefill moved from 9.7489 to 9.6905 seconds, about 0.6% faster.

## Correctness and stability gates

- coding, science, Malay, and planning outputs matched exact saved hashes;
- C2 exact admission and repeat identity passed;
- mid-prefill and mid-decode cancellation passed;
- cache integrity and final zero-use cleanup passed;
- the 17,490-token uncached prefill showed no material regression;
- native vision and operational gates passed;
- no new AER/BadTLP, Xid, MCE/EDAC, OOM, or service restart was observed.

The 786K geometry had already passed exact short and complex multi-hop outputs,
planted-key retrieval, cached follow-up, cancellation cleanup, C2 isolation,
near-ceiling stress, and concurrent 400K/496K work. Its minimum observed
authority free memory was 1,576.62 MiB. The functional 1M geometry was not
promoted because it did not retain the accepted margin.

## C2 latency behavior

Bounded prefill interleave reduced resident maximum pause:

| Partner prompt | Before | C2 interleave | Partner TTFT change |
| --- | ---: | ---: | ---: |
| 17,490 tokens | 9.807 s | 5.317 s | +0.76% |
| 40,000 tokens | 13.285 s | 4.200 s | +1.79% |
| 520,000 tokens | approximately full prefill | 4.016 s | +1.96% vs lone-prefill reference |

This is a fairness/latency improvement, not linear throughput scaling. Two active
decoders still share the same streamed expert banks, GPU kernels, collectives,
and authority.

## Scope and portability

Results apply to the qualified topology and software stack. Device UUIDs, local
paths, private endpoints, service-instance identifiers, and frontend settings are
intentionally excluded. Requalify after any GPU ordering, motherboard, riser,
firmware, driver, kernel, quantization, cache, context, or concurrency change.
