# DeepSeek V4.1 topology catalog

This directory catalogs accepted deployments without overwriting the evidence,
configuration, or conclusions of earlier work. A topology is a complete unit:
hardware order, expert placement, memory policy, source revision, performance,
correctness gates, and operational constraints must be considered together.

## Published topologies

| Date | Topology | Capacity | Status | Documentation |
| --- | --- | ---: | --- | --- |
| 2026-10-21 | 2x RTX 5090 + RTX 4090 48 GiB + RTX 4080 SUPER 32 GiB | 1,048,576 | Preserved packed-KV profile | [Top-level profile](../README.md) |
| 2026-10-30 | RTX 4090 48 GiB + RTX 4080 SUPER 32 GiB + 2x CMP 170HX 64 GiB | 524,288 | Frozen local production profile | [Dual-CMP resident-r3 final](dual-cmp-512k-residentr3-final/README.md) |

These profiles are not interchangeable presets. The 1M profile depends on its
RTX placement and exact packed-KV storage. The dual-CMP profile keeps packed KV
off, uses fully resident CMP expert banks, and has different prefill/decode
ownership. Select a profile by exact hardware and service objective, not only by
the advertised context length.
