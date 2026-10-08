# Decode ownership rebalance qualification

Date: 2026-10-01

## Accepted change

The 512K selective-P2P profile now assigns routed-expert decode ownership as
80 / 152 / 152 across the authority RTX 5090, worker RTX 5090, and modified
48 GiB RTX 4090. Prefill ownership remains 128 / 160 / 96. The stored expert
intervals expand to 0:128 / 80:208 / 232:152 so both phase-specific ownership
maps remain local.

The authority retains only 256 expert-cache slots because it also owns the dense
backbone and the physical KV cache. Profiling the former 112 / 136 / 136 split
measured approximately 27.1 ms of mapped-host expert refill per decode step on
the authority, versus 19.3 ms and 18.8 ms on the workers. FP4 expert compute was
only 3.7--4.7 ms per rank. Reducing authority ownership balances the refill
critical path without reducing the 8,192-token scheduler prefill chunk.

## Matched results

| Gate | 112 / 136 / 136 control | 80 / 152 / 152 | Change |
| --- | ---: | ---: | ---: |
| Short decode mean, five runs | 19.051 tok/s | 20.829 tok/s | +9.33% |
| Short decode median | 19.107 tok/s | 20.953 tok/s | +9.66% |
| 8K prefill mean, five runs | 1,460.940 tok/s | 1,456.583 tok/s | -0.30% |
| 520K prefill | 1,207.958 tok/s | 1,202.979 tok/s | -0.41% |

The topic-diverse coding, science, Malay, and planning probes improved by 8.4%,
5.0%, 5.5%, and 6.7% respectively and reproduced their accepted deterministic
output hashes.

## Correctness and capacity gates

- Two repeats reproduced every accepted short, arithmetic, code, and 8K retrieval
  hash.
- A 520,000-token prompt plus 31 generated tokens completed without OOM.
- Direct native OCR and authenticated Sembang raw-image OCR returned exact
  `7429`.
- Authenticated Sembang discovery, one-turn, and multi-turn completion passed.
- MTP and request concurrency remain disabled and were not part of this change.
