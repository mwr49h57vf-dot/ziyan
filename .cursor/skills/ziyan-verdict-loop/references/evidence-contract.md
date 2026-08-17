# Evidence contract

## Valid run

A valid device run has a unique `run_id` and persists these fields on the device before the host concludes:

- package version and script SHA;
- device tag, rootful/rootless path, session/request ID;
- gate start, phase ACKs, and one final classification;
- frame/session evidence appropriate to the gate;
- `FC_N`, `SB_CHG`, and post-stop residual state.

Host SSH output is convenience data. If it disconnects, reconnect and pull the device-side final artifact.

## Final classifications

| Class | Meaning | Product code change allowed? |
|---|---|---|
| `BUSINESS_PASS` | Expected script outcome and verified UI/foreground result | No, advance the matching gate only. |
| `TRANSPORT_BLOCKED` | SSH, SCP, service reachability, package, or script transfer unavailable | No. Repair the channel. |
| `INVALID_RUN` | No device-side final artifact, interrupted setup, stale prior session, or incomplete cleanup | No. Recover/clean and rerun. |
| `VISION_STALE` | Frame/front/lease is not current | Yes, capture/lease/front owner only. |
| `VISION_MISS` | Current valid frame did not match | Yes, matcher or test fixture only after evidence. |
| `TOUCH_SENT_NO_UI_CHANGE` | Visual match occurred but UI did not change | Yes, touch/verify owner only. |
| `RUNNER_ABORTED` | Script lifecycle or session stopped unexpectedly | Yes, runner/lifecycle owner only. |

## Required stop evidence

For every run or abort, verify:

`session=idle`, no live embed/runner marker, no keep residual, no touch-down residual, `FC_N=1` or documented idle state, and no new `SB_CHG`.

## Gate scope

- A `.149/.171` record is comparison-only.
- A rootful PASS does not prove rootless compatibility.
- An old package PASS does not prove the current package.
- Current Z2 is a four-device 30-minute gate. Three-hour stability is not a required gate.
