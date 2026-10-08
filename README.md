# DeepSeek V4.1 Flash on FreeToken

Reproducible deployment profile for the official DeepSeek-V4.1-Flash checkpoint
on two RTX 5090s, one 48 GiB RTX 4090, and one CMP 170HX. The three text ranks
use heterogeneous expert parallelism; the CMP runs only the native vision tower.
The authoritative expert and Engram banks remain pinned in host RAM.

The selected profile advertises 524,288 tokens, keeps the public prefill chunk at
8,192 tokens, and uses direct P2P only between the two qualified RTX 5090s.
Request concurrency remains one. DSpark/MTP is present in the pinned FreeToken
revision as an experimental opt-in but is disabled by this profile.

## Pinned stack

- Model: `deepseek-ai/DeepSeek-V4.1-Flash`
- Model revision: `dba1be0a40aa45a94ad051997016db3960a90277`
- FreeToken branch: <https://github.com/Enigmatic331/FreeToken/tree/dsv41-phase-split-ep3>
- Qualified FreeToken revision: `666248a0803da9217a3614e7eb78355fc6c7b60c`
- Checkpoint: 48 shards, 510,286,023,000 indexed tensor bytes

Exact pins are recorded in [`freetoken.lock`](freetoken.lock).

## Qualified placement

| Role | Rank 0 / RTX 5090 | Rank 1 / RTX 5090 | Rank 2 / RTX 4090 |
| --- | ---: | ---: | ---: |
| Decode-owned experts | 80 | 152 | 152 |
| Prefill-owned experts | 128 | 160 | 96 |
| Stored expert range | `0:128` | `80:208` | `232:152` |
| MoE cache slots | 256 | 1,472 | 2,350 |
| Dense/attention/KV authority | yes | no | no |

The two RTX 5090 ranks also own the row-sharded Engram tables. The CMP 170HX is
visible only to rank 0 as the vision device; it is not part of the text
communicator and holds no text worker.

Material runtime geometry:

```text
Context:             524,288 tokens
Full KV pages:       4,096 x 128 tokens, authority only
Scheduler prefill:   8,192 tokens
Internal EP tile:    4,096 tokens
Indexer-logit cap:   256 MiB
Text transport:      RTX 5090 pair P2P; RTX 4090 edges shared memory
Concurrency:         one request
Vision:              native checkpoint tower on the CMP 170HX
MTP:                 disabled
```

## Accepted performance

All figures are batch-one measurements on the qualified host, not portable
promises.

| Gate | P2P disabled | Selective 5090 P2P | Change |
| --- | ---: | ---: | ---: |
| 8,192-token prefill, five-run mean | 1,302.915 tok/s | 1,460.940 tok/s | +12.13% |
| 512-prompt/127-completion decode, five-run mean | 19.155 tok/s | 19.522 tok/s | +1.92% |
| 520,000-token capacity prefill | 1,090.648 tok/s | 1,207.958 tok/s | +10.75% |

The 520K selective-P2P request generated 31 additional tokens at 17.472 tok/s.
Peak observed allocations were 32,136 MiB, 30,021 MiB, and 45,146 MiB across
the three text GPUs. The authority briefly reached approximately 35 MiB free,
so this is a validated ceiling rather than spare capacity.

After the P2P qualification, decode ownership was rebalanced away from the
cache-constrained authority. A fresh five-run matched A/B improved short decode
from 19.051 to 20.829 tok/s (+9.33%). The same placement retained 1,456.583
tok/s mean 8K prefill (-0.30%) and completed the 520K gate at 1,202.979 tok/s
(-0.41%).

The exact short/code/retrieval oracle, native image OCR, a 520K capacity request,
clean cold start, and frontend completion path all passed. See
[`docs/qualification-512k.md`](docs/qualification-512k.md) and
[`docs/qualification-decode-ownership.md`](docs/qualification-decode-ownership.md), plus
[`results/production-512k.csv`](results/production-512k.csv).

## Deploy

1. Clone the pinned FreeToken fork and check out the revision in
   [`freetoken.lock`](freetoken.lock).
2. Install FreeToken using its upstream instructions in a dedicated environment.
3. Download all 48 official checkpoint shards and tokenizer/config files.
4. Copy [`.env.example`](.env.example) to a host-only file, restrict its
   permissions, and replace the placeholder paths and device selection.
5. Run [`scripts/preflight.sh`](scripts/preflight.sh).
6. Run [`scripts/run.sh`](scripts/run.sh) in the foreground for qualification.
7. Run [`scripts/smoke-test.sh`](scripts/smoke-test.sh), the deterministic oracle,
   a real image OCR gate, and an appropriate long-context gate.
8. Install the reviewed systemd template only after adapting its generic service
   user and paths.

The example binds to loopback. Choose a deliberately firewalled internal address
only when a separate frontend must connect from another network namespace.

## Safety notes

- Keep concurrency at one for this geometry.
- Do not raise the 8,192-token scheduler chunk, 4,096-token route tile, authority
  cache, or KV pages without repeating the 520K capacity gate.
- Do not assume P2P from model names. Verify pairwise access, payload integrity,
  and bandwidth after any driver, kernel, BIOS, motherboard, or slot change.
- Only the RTX 5090 pair is expected to use P2P. The RTX 4090 and vision device
  must retain a non-P2P path.
- Keep `LimitMEMLOCK=infinity`; pinned host banks are part of the runtime design.
- Do not enable DSpark/MTP or request concurrency as part of this production
  profile. Each requires a separate correctness and throughput qualification.

See [`docs/architecture.md`](docs/architecture.md) for placement constraints and
[`docs/operations.md`](docs/operations.md) for startup, monitoring, and rollback.
