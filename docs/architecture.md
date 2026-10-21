# Architecture and correctness constraints

## Execution design

FreeToken starts four text processes. Rank 0 owns the complete TP1 backbone,
dense layers, sparse attention, physical KV, shared experts, logits, and sampling.
Ranks 1–3 are expert workers. Rank 3 also runs native vision. Engram remains
row-sharded over the two RTX 5090 ranks.

The workload uses distinct prefill and decode ownership:

| Rank | Device class | Prefill experts | Decode experts | Stored interval | Cache slots |
| ---: | --- | ---: | ---: | --- | ---: |
| 0 | RTX 5090 authority | 112 | 16 | `[0,112)` | 240 |
| 1 | RTX 5090 worker | 128 | 136 | `[16,240)` | 1,536 |
| 2 | modified RTX 4090 48 GiB | 112 | 160 | `[144,352)` | 2,494 |
| 3 | modified RTX 4080 SUPER 32 GiB | 32 | 72 | `[288,384)` | 1,552 |

Overlapping storage lets ownership change at the phase boundary without rereading
the complete expert bank. Grouped packed transport returns only routed outputs.
Host RAM is both the pinned authoritative weight tier and the source for bounded
CPU assistance: two disjoint 24-thread pools serve ranks 1 and 2, with one GPU
fetch plus at most one CPU-computed miss per layer under the accepted policy.

## Exact packed KV and the 1M boundary

Only rank 0 owns physical attention KV. Expert-only ranks retain metadata-only
pools. DeepSeek V4.1 rounds every 512-channel compressed main-KV row to E2M1 FP4
with one E4M3 scale per 16 channels before it enters the cache. Earlier FreeToken
expanded those already-rounded values into 1,024 BF16 bytes per row. The final
branch stores 256 bytes of nibbles plus 32 scale bytes and can reconstruct the
same BF16 bits, including signed zero. This shrinks persistent compressed main-KV
storage by about 3.6x without adding another quantization step.

The 8,192 main pages at 128 tokens/page provide the 1,048,576-token ceiling. SWA
remains BF16 and fixed at 1,152 physical pages through the 0.140625 ratio. Packed
prefill uses the qualified Gluon path; graph-captured M=1 decode expands only the
selected rows into a transient BF16 staging slab and then reuses the original
attention order.

The capacity gate used a cold 1,040,000-token prompt with planted keys at four
depths. It returned every key exactly and in order, peaked at 8,126/8,192 pages,
and left 2,288.62 MiB free on the authority GPU. The packed 1M profile preserved
short output hashes and decode/prefill performance within measurement noise of
the accepted packed 786K control.

Workspace control still depends on:

- a 256 MiB indexer-logit ceiling;
- compact prefill candidates and sparse consumer logits;
- 8,192-token scheduler chunks split into exact 4,096-token route tiles;
- native BF16 head storage with FP32 logits;
- worker Engram scratch reuse and phase-aware cache priority.

## Native multimodal placement

The checkpoint's image processor and vision tower are native FreeToken paths.
Rank 3 runs vision on the same 4080 SUPER that owns its text-expert share. Final
visual embeddings return to rank 0. Raw pixels are not fanned out to the other
expert workers.

Network image fetching rejects credentials, non-HTTP(S) schemes, non-public
addresses, and unsafe redirects. Production frontends may instead send bounded
base64 image parts directly.

## Selective P2P

Rank-local visibility keeps each assigned device first while exposing qualified
text peers so NCCL can select transport per edge. On the accepted topology:

- the RTX 5090 pair uses direct P2P;
- every RTX 4090/4080 edge uses the non-P2P shared-memory path.

This is hardware- and software-stack-specific. A new host must pass pairwise
byte-integrity and bandwidth tests before enabling the profile.

## C2 scheduling

The scheduler admits at most two requests. Stateful V4.1 compression/Engram and
KV state remain isolated per request. One resident decode step may run between
ordinary 8K prefill chunks; the first and final chunks, paired head/tail forward,
dependency-cone boundaries, and numerical kernels remain unchanged. This reduces
long stalls but does not make two streams independently achieve the single-stream
peak.

## Promoted execution features

The final branch includes the accumulated exact-output work through 2026-10-16:

- decode-refill overlap, fused route preparation, and fused decode dispatch;
- tuned native FP8 decode kernels without changing checkpoint quantization;
- single-miss background admission, empty-cache guard, fused CPU preparation,
  paired CPU DS-FP4 tiles, and bounded warm wait;
- compact/sparse prefill logits, inactive-rank skipping, grouped/async packed
  transport, tail pairing, and the long-prompt dependency cone;
- C2 bounded prefill interleave;
- authority-side M=1/M=2 fusion;
- token-boundary metadata overlap;
- exact packed FP4+scale main-KV storage, packed-prefill Gluon, and transient
  BF16 decode staging;
- MoE hot-path statistics collection disabled; cache reporting retained.

## Correctness boundary

- Dense/attention/KV and sampling authority remain on rank 0.
- Expert ownership totals exactly 384 in both phases.
- Engram remains on the two homogeneous RTX 5090 ranks.
- Scheduler chunk and internal route tile remain 8,192/4,096 tokens.
- CUDA graphs are qualified through batch size two only.
- Native vision remains on rank 3 and follows the same ordered control protocol.
- MTP remains disabled.
- Main-KV packing is startup-only and must not change under live pages or
  captured graphs; SWA remains BF16.
- Capacity, cache, route, graph, topology, quant, or concurrency changes require
  exact text/code/retrieval, native-image, cancellation, cache-integrity, and
  long-context gates before performance acceptance.

## Current bottleneck

The packed 1M profile sustains about 40.175 tok/s, or 24.891 ms/token. Remaining
time is spread across backbone/attention/router work, routed experts and host
refill, collectives/authority work, and token-boundary orchestration. The profile
is no longer explained by one unambiguously dominant copy alone. Additional VRAM
or another GPU helps only if it changes ownership/cache locality or removes a
critical communication edge; capacity by itself is not a throughput guarantee.
