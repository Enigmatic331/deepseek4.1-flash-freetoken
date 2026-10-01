# 512K heterogeneous production qualification

Date: 2026-10-01

## Accepted outcome

The official DeepSeek-V4.1-Flash checkpoint completed a 520,000-token prompt and
31-token generation on two RTX 5090 text ranks plus one 48 GiB RTX 4090 expert
rank. Native vision ran independently on a CMP 170HX. The selected service
advertises 524,288 tokens and one request at a time.

The qualification labels in this document are measurements on one rig. They do
not imply equivalent behavior on another motherboard, driver, kernel, or slot
layout.

## Capacity result

With P2P disabled, the accepted 520K control measured:

- 476.781 seconds TTFT;
- 1,090.648 prefill tok/s;
- 14.417 decode tok/s;
- 32,140 / 29,074 / 44,429 MiB observed text-GPU peaks.

With selective RTX 5090 P2P enabled, the matched capacity request measured:

- 430.479 seconds TTFT;
- 1,207.958 prefill tok/s;
- 17.472 decode tok/s;
- 32,136 / 30,021 / 45,146 MiB observed text-GPU peaks.

The prompt and generation completed correctly. The authority briefly reached
approximately 35 MiB free, making this a deliberately tight ceiling.

## Selective-P2P A/B

| Gate | P2P off | Selective P2P | Change |
| --- | ---: | ---: | ---: |
| 8K prefill mean, five runs | 1,302.915 tok/s | 1,460.940 tok/s | +12.13% |
| 8K prefill median | 1,302.381 tok/s | 1,459.627 tok/s | +12.07% |
| Short decode mean, five runs | 19.155 tok/s | 19.522 tok/s | +1.92% |
| Short decode median | 19.304 tok/s | 19.573 tok/s | +1.39% |
| 520K prefill | 1,090.648 tok/s | 1,207.958 tok/s | +10.75% |

NCCL selected direct `P2P/CUMEM` only between the RTX 5090s and shared memory for
all RTX 4090 edges. The vision device remained outside the text communicator.

## Correctness gates

- Two candidate repeats reproduced the accepted deterministic hashes for the
  short knowledge, multiplication, Python, and 8,217-token retrieval probes.
- The production restart reproduced the same oracle.
- Native image OCR returned the expected fixture value before and after promotion.
- A clean cold load completed with zero automatic restarts.
- The public 8,192-token prefill chunk remained unchanged.

## Limitations

- Request concurrency is unqualified and remains one.
- DSpark/MTP is slower than target-only decode on the measured workloads and is
  disabled.
- The profile does not shard dense layers, attention, or KV.
- The RTX 4090 and CMP 170HX have no qualified P2P path to the RTX 5090s.
- Any topology or software-stack change invalidates the P2P assumption until
  pairwise integrity and bandwidth are rechecked.
