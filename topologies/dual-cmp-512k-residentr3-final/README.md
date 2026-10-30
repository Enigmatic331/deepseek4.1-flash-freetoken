# Dual-CMP 512K resident-r3 final topology

Frozen: 2026-10-30  
Role: local DeepSeek V4.1 Flash production topology  
Capacity: 524,288 tokens  
Concurrency: one request

This topology is published separately from the earlier 1M four-RTX profile so
both lines of work remain reproducible. It targets a heterogeneous four-rank
host with two fast RTX ranks and two 64 GiB CMP expert-bank ranks. The retained
design prioritizes exactness, zero static-CMP expert misses, long-context
capacity, and boot-ready operation while improving the measured 40K prefill
path without materially regressing decode.

## Source pin

- FreeToken branch: [`dsv41-512k-residentr3-final`](https://github.com/Enigmatic331/FreeToken/tree/dsv41-512k-residentr3-final)
- Qualified commit: [`7663e3a24e9e35b80e09a20df0f336d204df6cd3`](https://github.com/Enigmatic331/FreeToken/commit/7663e3a24e9e35b80e09a20df0f336d204df6cd3)
- Base commit: `5b0a6310e69fdc6752b79bf9b974b66b12347aae`
- Model: `deepseek-ai/DeepSeek-V4.1-Flash-1017`

Machine-readable source and capacity pins are in [`topology.lock`](topology.lock).

The release commit contains the seven qualified source/test changes only. It
adds the SM89 decode policy, active-prefill subgroup broadcast, pairwise packed
prefill route communicators, the architecture-gated SM80 FP4 prefill launch
policy, and their policy tests.

## Frozen placement

| Role | Rank 0 | Rank 1 | Rank 2 | Rank 3 |
| --- | ---: | ---: | ---: | ---: |
| Device | RTX 4090 48 GiB | RTX 4080 SUPER 32 GiB | CMP 170HX x4 64 GiB | CMP 170HX x16 64 GiB |
| Decode-owned experts | 80 | 140 | 84 | 80 |
| Prefill-owned experts | 160 | 144 | 0 | 80 |
| Stored expert range | `0:160` | `80:224` | `220:84` | `304:80` |
| MoE cache slots | 960 | 1,472 | 3,360 | 3,360 |

Material runtime policy:

```text
Context:                 524,288 tokens
Backbone/attention/KV:   rank 0
Engram:                  ranks 0 and 1
Main KV pages:           4,096 x 128 tokens
Physical SWA pages:      1,152 x 128 tokens
Packed KV:               off
Head:                    native BF16
SM89 FP8 decode:         enabled for qualified shapes
SM80 FP4 prefill:        m64n32w4s2
MTP:                     off
P2P/IB collectives:      disabled
Static CMP misses:       hard rejection condition
```

The CMP ranks are fully resident expert banks. Rank 2 is intentionally excluded
from prefill ownership in the accepted placement; rank 3 contributes a bounded
80-expert prefill shard. Extra CMP VRAM is used for residency and cache headroom,
not for packed KV or speculative capacity claims.

## Accepted performance

Measurements are specific to the qualified host and cold-cache conditions.

| Gate | Control | Final candidate | Change |
| --- | ---: | ---: | ---: |
| Cold 40K TTFT | 35.6911 s | 33.2262 s median | -6.91% |
| Cold 40K effective prefill | — | 1,203.87 tok/s | three exact repeats |
| Near-capacity 506K TTFT | 520.0370 s | 517.8711 s | -0.42% |
| Short-context decode | 21.4281 tok/s | 21.3776 tok/s median | -0.24% |
| SM80 real-bank kernel fixture | 39.5837 ms | 35.3864 ms | -10.60% |

The 40K mean TTFT 95% interval was 33.1110-33.3578 seconds. The 506K gate used
3,954/4,096 main-KV pages, returned the planted retrieval exactly, recorded zero
static-CMP misses, and released KV/SWA pages to zero. The 30-minute 512K soak
completed with zero terminal faults, 70 C maximum GPU temperature, 56 C maximum
DIMM temperature, and zero KV/SWA residue.

The release cancellation gate aborted a real 40K prefill without a restart,
counter leak, or final KV/SWA residue. A deliberately short four-second wait
observed HTTP 503 before terminal acknowledgement; the same instance reached
fully idle zero-accounting state seconds later. This is accepted as bounded slow
cancellation, not instantaneous cancellation.

Machine-readable headline values are in [`results.csv`](results.csv).

## Production behavior

The production identity uses a loopback model service, an instance-specific
prewarm certificate, a stable socket-proxied ingress for local applications, and
a two-strike watchdog. The ingress remains closed until model identity, context
capacity, sampler warmup, exact ORBIT gates, and post-request KV/SWA cleanup all
pass. See [`operations.md`](operations.md) for the boot and recovery contract.

## Boundaries

- Do not combine this placement with the earlier 1M packed-KV profile.
- Do not enable packed KV, MTP, P2P, or CPU-hybrid CMP misses without a new
  correctness and matched-performance qualification.
- Preserve logical device order; the rank numbers are part of the topology.
- A static-CMP miss/refill, output mismatch, NaN/repetition collapse, service
  restart, OOM, throttle, Xid/AER/MCE/EDAC event, or non-zero cleanup residue
  invalidates a performance result.
- Requalify after relevant driver, kernel, BIOS, PCIe, or accelerator changes.
