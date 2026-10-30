# Operations contract

This page records the operational shape of the frozen dual-CMP topology. The
installed systemd units remain authoritative for the qualified host. Exact
hardware bindings are recorded only where required to reproduce the qualified
boot policy.

## Service identities

- Model: `freetoken-dsv41-production.service`
- Prewarm: `freetoken-dsv41-production-prewarm.service`
- Stable ingress: `freetoken-dsv41-production-ingress.socket`
- Watchdog: `freetoken-dsv41-production-watchdog.timer`
- Direct endpoint: `127.0.0.1:19291`
- Stable local-application ingress: `172.17.0.1:1919`

## Hardware-rate boot gate

The qualified host restricts `gpu-unlock/1.1.1` to the RTX 4090 at
`0000:c1:00.0` and RTX 4080 SUPER at `0000:45:00.0`, with the explicit AD103
experimental flag. Wildcard targeting is not permitted. An enabled post-boot
collector binds RM reads to the expected GPU UUIDs and requires `fmla32=0`,
`imla2=0`, and `imla4=0` on both GPUs plus both exact kernel unlock events.
Performance evidence is invalid unless its per-boot verdict is `PASS`.

## Boot/readiness sequence

1. Cooling control and the local container runtime start.
2. The model service loads on loopback with the frozen rank order and geometry.
3. Prewarm waits for exact model, checkpoint-root, and 524,288-token identity.
4. Prewarm exercises stochastic non-thinking generation, exact ORBIT, and exact
   omitted-`max_tokens` behavior.
5. Prewarm requires zero active requests and explicit zero main-KV/SWA usage
   after the requests, then writes a certificate bound to the model instance ID.
6. The separately enabled stable ingress opens only after that certificate
   succeeds. The model unit pulls prewarm, but must not directly pull ingress;
   that would create an ordering cycle because ingress itself waits for prewarm.
7. The watchdog checks every three minutes, allows a 30-minute startup grace,
   defers while a request is active, and requires two consecutive failures before
   bounded local recovery.

The prewarm helper may accept `null` KV/SWA telemetry only for a brand-new
instance with zero active and zero completed requests. Once any request has run,
cleanup must report numeric zero.

The receipt writer uses a per-process temporary file in the receipt directory
and atomically replaces the final JSON. This prevents a stale fixed-name file
owned by an earlier privileged run from blocking a later prewarm.

## Routine checks

```bash
systemctl status freetoken-dsv41-production.service
systemctl status freetoken-dsv41-production-prewarm.service
systemctl status freetoken-dsv41-production-ingress.socket
systemctl status freetoken-dsv41-production-watchdog.timer
curl -fsS http://127.0.0.1:19291/health
curl -fsS http://172.17.0.1:1919/health
cat /proc/cmdline
cat /home/enigmatic331/models/dsv41-flash-results/2026-10-30-ada-tensor-unlock/postboot/$(cat /proc/sys/kernel/random/boot_id)/postboot-verdict.txt
```

The model listing must advertise 524,288 tokens. A healthy idle service must
show zero active requests and zero main/SWA KV pages. Inspect accelerator and
DIMM temperatures plus kernel/service logs before accepting a performance run.

## Restart and rollback

Close stable ingress before a controlled model restart, request an orderly drain
and abort through the administrative stop endpoint, then let systemd restore the
prewarm-to-ingress dependency chain. Do not expose the instance before the new
prewarm certificate is bound to its instance ID.

The retained rollback is the previously proven 384K control-C service. A rollback
must be treated as a full topology transition: stop stable ingress, stop and
disable the 512K production unit, start the 384K unit, then repeat identity,
correctness, cancellation cleanup, and hardware-safety checks before exposing it.
Never bind both services to the same ingress port.

The Ada-rate policy has an independent rollback: restore the saved stock GRUB
defaults, regenerate GRUB configuration, and reboot. Do not treat a model-unit
restart as a substitute for this boot-policy rollback.
