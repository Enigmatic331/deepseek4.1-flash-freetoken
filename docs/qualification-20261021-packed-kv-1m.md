# Packed-KV 1M production qualification

Date: 2026-10-21

## Accepted outcome

FreeToken revision `5b0a6310e69fdc6752b79bf9b974b66b12347aae` adds an
exact packed representation for DeepSeek V4.1's compressed main KV. The
DeepSeek computation already rounds each row to E2M1 FP4 with one E4M3 scale per
16 channels. FreeToken now retains those nibbles and raw scale bytes in the
persistent cache instead of storing their BF16 expansion. Unpacking reproduces
the same BF16 bits, including signed zero.

The packed storage, packed-prefill Gluon kernel, and transient BF16 decode
staging were qualified together at a 1,048,576-token context. SWA remains BF16.

## Qualified stack and geometry

- model: `deepseek-ai/DeepSeek-V4.1-Flash-1017`
- model revision: `1bae0e1088993b9b82de08f59de5be5a34e42170`
- context: 1,048,576 tokens
- main KV: 8,192 pages of 128 tokens
- SWA: 1,152 BF16 pages of 128 tokens
- decode ownership: 16 / 136 / 160 / 72
- prefill ownership: 112 / 128 / 112 / 32
- stored ranges: 0:112 / 16:224 / 144:208 / 288:96
- MoE caches: 240 / 1,536 / 2,494 / 1,552
- concurrency: maximum two requests
- DSpark/MTP: disabled

## Performance

| Gate | Previous accepted packed control | Packed-KV 1M | Change |
| --- | ---: | ---: | ---: |
| Stable single-stream decode mean | 40.222 tok/s | 40.175 tok/s | -0.12% |
| Stable time per token | — | 24.891 ms | — |
| Cold 4,096-token TTFT | 3.912 s | 3.905 s | -0.18% |
| Cold 17,490-token TTFT | 9.814 s | 9.778 s | -0.37% |
| Cold 40,000-token TTFT | — | 13.891 s | — |

The three short-decode repetitions had the same output hash. The small decode
and prefill differences are within measurement noise.

## Near-ceiling correctness and capacity

A cold 1,040,000-token prompt planted unique keys at token depths 103,116,
519,480, and 935,843. The completion returned all keys exactly and in order.

- TTFT: 361.061 seconds
- aggregate prompt rate: 2,880.4 tok/s
- main-KV peak: 8,126/8,192 pages (99.2%)
- completion: 17 tokens, normal stop
- authority free VRAM floor: 2,288.62 MiB
- main KV and SWA returned to zero immediately after completion

Exact sentinel checks passed before and after the capacity run. No cache leak,
service restart, CUDA error, OOM, thermal throttle, Xid, AER, MCE, or EDAC event
was observed. Peak DIMM temperature was 59 C.

## Operational boundary

All three packed-KV switches are startup-only. Do not change the cache
representation under live pages or captured CUDA graphs. Any change to packed
sources, page count, SWA ratio, prefill/decode kernels, cache allocation, or
concurrency requires the same exact-output, cancellation, native-image,
near-ceiling, cleanup, and hardware-error gates.

