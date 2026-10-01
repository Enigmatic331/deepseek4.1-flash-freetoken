# Architecture and correctness constraints

## Execution design

FreeToken starts three text processes. Rank 0 owns the complete TP1 backbone,
dense layers, sparse attention, KV, shared experts, logits, sampling, and native
vision integration. Ranks 1 and 2 are expert workers. Engram remains row-sharded
over the two RTX 5090 ranks; the RTX 4090 does not participate in Engram.

The workload has distinct prefill and decode ownership:

| Rank | Device class | Prefill experts | Decode experts | Stored interval |
| ---: | --- | ---: | ---: | --- |
| 0 | RTX 5090 | 128 | 112 | `[0,128)` |
| 1 | RTX 5090 | 160 | 136 | `[112,288)` |
| 2 | RTX 4090 48 GiB | 96 | 136 | `[248,384)` |

Overlapping storage lets ownership change at the phase boundary without rereading
the full bank. Multi-peer packed transport returns only each worker's routed
outputs. Host RAM is a pinned weight tier; it is not CPU expert execution.

## KV and the 512K boundary

Only rank 0 owns physical attention KV. Ranks 1 and 2 retain metadata-only pools.
The 4,096 full pages at 128 tokens/page provide a 524,288-token slab; the
authority KV payload is approximately 7.22 GiB. This placement avoids duplicating
the attention state on expert-only ranks.

The decisive capacity failures were transient workspace failures, not late KV
growth. Three changes made the 512K profile viable:

- indexer masking no longer creates a 512 MiB temporary;
- hidden-cache normalization avoids a 640 MiB `square()` temporary;
- each 8,192-token scheduler chunk is routed as two exact 4,096-token EP tiles,
  reducing the largest route tensor from 480 MiB to 240 MiB.

The rank-0 cache is 256 slots, the safe floor retaining two complete 128-expert
prefill buffers. Raising it removes capacity margin; lowering it gives up the
copy/compute overlap that protects prefill.

## Native multimodal placement

The checkpoint's image processor and vision tower are native FreeToken paths.
Only rank 0 can see the auxiliary vision GPU. Image patches execute there and the
final visual embeddings return to rank 0. Raw pixels are not fanned out to expert
workers, and the vision GPU is not a text communicator member.

Network image fetching rejects credentials, non-HTTP(S) schemes, non-public
addresses, and unsafe redirects. Production frontends may instead send bounded
base64 image parts directly.

## Selective P2P

Pure one-GPU-per-rank visibility hid enough physical topology that NCCL could not
choose transport safely per pair. Enabling P2P in that layout caused an unsupported
peer-access attempt on heterogeneous edges.

The accepted opt-in layout keeps each assigned text device first as local
`cuda:0`, then exposes the other text devices as topology peers. NCCL selected:

- `P2P/CUMEM` for RTX 5090 to RTX 5090 traffic;
- `SHM/direct/direct` for every RTX 4090 edge.

The vision GPU remains owner-only. Peer visibility does not place another rank's
model on that GPU; it supplies topology information and creates small peer
contexts. On the qualified host the authority's critical free-memory difference
versus P2P-off was approximately 30 MiB.

This behavior is hardware- and software-stack-specific. A new host must pass
pairwise byte-integrity and bandwidth tests before enabling the profile.

## Correctness boundary

- Dense/attention/KV and sampling authority remain on rank 0.
- Expert ownership totals exactly 384 in both phases.
- Engram remains on the two homogeneous RTX 5090 ranks.
- The scheduler chunk remains 8,192 and the internal exact route tile 4,096.
- CUDA graphs remain batch-one and position-aware.
- Native vision is isolated from text collectives.
- DSpark/MTP and multi-request concurrency remain disabled.
- Capacity, cache, route, graph, topology, or driver changes require the exact
  oracle, image OCR, and long-context gates before performance acceptance.

## Current bottlenecks

The 12.13% matched prefill gain from RTX 5090 P2P shows that inter-rank transport
was material. Decode improved only 1.92%, so its next targets are expert fetch and
overlap behavior followed by the FP4 decode kernel. KV sharding is not part of the
current plan because the MLA authority state is already compact relative to the
expert and workspace costs.
