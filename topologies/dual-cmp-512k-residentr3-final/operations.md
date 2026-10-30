# Operations contract

This page records the operational shape of the frozen dual-CMP topology. The
installed systemd units remain authoritative for the qualified host; this public
document deliberately avoids host-specific paths and device identifiers.

## Service identities

- Model: `freetoken-dsv41-production.service`
- Prewarm: `freetoken-dsv41-production-prewarm.service`
- Stable ingress: `freetoken-dsv41-production-ingress.socket`
- Watchdog: `freetoken-dsv41-production-watchdog.timer`
- Direct endpoint: `127.0.0.1:19291`
- Stable local-application ingress: `172.17.0.1:1919`

## Boot/readiness sequence

1. Cooling control and the local container runtime start.
2. The model service loads on loopback with the frozen rank order and geometry.
3. Prewarm waits for exact model, checkpoint-root, and 524,288-token identity.
4. Prewarm exercises stochastic non-thinking generation, exact ORBIT, and exact
   omitted-`max_tokens` behavior.
5. Prewarm requires zero active requests and explicit zero main-KV/SWA usage
   after the requests, then writes a certificate bound to the model instance ID.
6. The stable ingress opens only after that certificate succeeds.
7. The watchdog checks every three minutes, allows a 30-minute startup grace,
   defers while a request is active, and requires two consecutive failures before
   bounded local recovery.

The prewarm helper may accept `null` KV/SWA telemetry only for a brand-new
instance with zero active and zero completed requests. Once any request has run,
cleanup must report numeric zero.

## Routine checks

```bash
systemctl status freetoken-dsv41-production.service
systemctl status freetoken-dsv41-production-prewarm.service
systemctl status freetoken-dsv41-production-ingress.socket
systemctl status freetoken-dsv41-production-watchdog.timer
curl -fsS http://127.0.0.1:19291/health
curl -fsS http://172.17.0.1:1919/health
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
