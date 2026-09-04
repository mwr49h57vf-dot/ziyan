# BackBoard Touch Comparison and Fix Implementation Plan

> **For agentic workers:** Execute this plan task-by-task with a verification checkpoint after each task.

**Goal:** Compare the historical TouchSprite BackBoard event path with ZiYan BBTouch, correct the single owning dispatch defect while preserving exact tap coordinates, then validate both package architectures on all four devices.

**Architecture:** Keep Lua coordinate production and `tap(x, y)` argument passthrough unchanged. Trace and fix only the ZiYan BackBoard event construction/delivery/consumption boundary, retaining the existing app-first and BB fallback policy. Use static contracts, package SHA checks, no-auto-restart install evidence, and the existing serial business gate as the acceptance chain.

**Tech Stack:** Objective-C, Theos Debian packages, IOHID/BackBoard private runtime symbols, Lua, shell-based device gates, Python contract fixtures.

**Spec:** `/Users/mac/Desktop/ZiYan_副本/tmp_shots/HISTORICAL_DEB_CLICK_AUDIT_20260902_031516/`

## Global Constraints

- Never modify `/Users/mac/Desktop/ios7.lua` or `/Users/mac/Desktop/ios8p.lua`.
- Every `tap(x, y)` coordinate remains the exact supplied value; no randomization, offset, or second compensating tap.
- Do not link TouchSprite dylibs or TSDaemon; use the historical package only as a read-only structural reference.
- Do not use `sbreload`, `killall`, reboot, or SpringBoard/BackBoard restart during deployment or validation.
- Validate devices serially in `.101 → .112 → .166 → .53` order; stop on the first non-PASS result.
- Preserve `FC_N=1`, `SB_CHG=0`, cleanup state, rollback evidence, and rootful/rootless package identity.

### Task 1: Complete the BackBoard path comparison

**Files:**
- Read: `/Users/mac/Desktop/ZiYan_副本/tmp_shots/HISTORICAL_DEB_CLICK_AUDIT_20260902_031516/touchsprite_injection_filters.txt`
- Read: `/Users/mac/Desktop/ZiYan_副本/tmp_shots/HISTORICAL_DEB_CLICK_AUDIT_20260902_031516/touchsprite_event_dylib_strings.txt`
- Read: `/Users/mac/Desktop/ZiYan_副本/tmp_shots/HISTORICAL_DEB_CLICK_AUDIT_20260902_031516/touchsprite_historical_behavior_evidence.txt`
- Read: `objc/tweak/bbtouch/Tweak.m`
- Read: `objc/shared/ZiYanTouchBridge.m`
- Read: `objc/tweak/springboard/ZiYanScreenBridge.m`
- Read: `objc/shared/ZiYanHIDOptimizer.m`
- Create: `tmp_shots/HISTORICAL_DEB_CLICK_COMPARE_20260902/VERDICT.md`

**Interfaces:**
- Consumes: historical plist/filter evidence and current ZiYan receive/dispatch/UI-consumption markers.
- Produces: one root-cause statement naming the exact owning method and one minimal-change hypothesis.

- [ ] Extract historical injection scope, event shape, dispatch API, and target-consumption evidence.
- [ ] Trace current request marker → BackBoard receiver → event construction → dispatch → UI-consumption marker.
- [ ] Record every mismatch and classify it as capture, coordinate mapping, event shape, dispatch, lifecycle, or UI-consumer evidence.
- [ ] Stop analysis before editing until one owning mismatch is supported by source and device logs.

### Task 2: Add the smallest regression contract and implement one owning fix

**Files:**
- Create or modify: `tools/test_bbtouch_backboard_dispatch_contract.py`
- Modify only the owning Objective-C file identified by Task 1, expected candidates `objc/shared/ZiYanTouchBridge.m` or `objc/tweak/bbtouch/Tweak.m`
- Do not modify: `lua/modules/Touch.lua`, `lua/ziyan_engine/touch.lua`, `/Users/mac/Desktop/ios7.lua`, `/Users/mac/Desktop/ios8p.lua`

**Interfaces:**
- Consumes: Task 1 root-cause statement.
- Produces: a contract that verifies BackBoard-level delivery metadata and exact coordinate passthrough.

- [ ] Write a contract that fails for the identified mismatch and asserts exact `x,y` preservation.
- [ ] Run the contract and capture the failure before source change.
- [ ] Implement only the single owning change; do not add coordinate transforms, retries, random fingers, or app-specific Bundle rules.
- [ ] Run the contract, focused existing tap contracts, `git diff --check`, and the relevant compile target.

### Task 3: Build and package both architectures

**Files:**
- Modify only generated build outputs under `packages/` and evidence under `tmp_shots/`.
- Read: `tools/zy_dual_package.sh`, `control`, `Makefile`.

**Interfaces:**
- Consumes: Task 2 source and contracts.
- Produces: one rootful `iphoneos-arm` package and one rootless `iphoneos-arm64` package with SHA-256, version, architecture, install-name, and no-restart evidence.

- [ ] Build rootful and rootless packages with the existing dual-package command.
- [ ] Verify package architecture, package version, relevant install names, and SHA-256.
- [ ] Record a rollback point and package evidence before touching `.101`.

### Task 4: Serial four-device deployment and business validation

**Files:**
- Read: `tools/zy_run1_script_logic_gate.sh`
- Create: `tmp_shots/DEPLOY_BACKBOARD_FIX_*` and `tmp_shots/RUN1_GATE_*` evidence directories.

**Interfaces:**
- Consumes: Task 3 package identities and SHAs.
- Produces: four current device verdicts with `BUSINESS_PASS`, `FIND_TAP=1`, `CLICK=1`, `FC_N=1`, and `SB_CHG=0`.

- [ ] Deploy rootful to `.101`, require desktop precondition and no restart, then run the `ios7.lua` gate.
- [ ] Only after `.101` PASS, deploy rootful to `.112` and run its gate.
- [ ] Only after `.112` PASS, deploy rootful to `.166` and run its gate.
- [ ] Only after `.166` PASS, deploy rootless to `.53` and run its `ios8p.lua` gate.
- [ ] Preserve failed or inconclusive evidence; never convert a transport or precondition result into a business PASS.

### Task 5: Close the checkpoint

**Files:**
- Modify: `.codex/ZIYAN_ACTIVE_CHECKPOINT.json`
- Create: `tmp_shots/HISTORICAL_DEB_CLICK_COMPARE_20260902/FINAL_SUMMARY.md`

**Interfaces:**
- Consumes: all prior evidence and command exit statuses.
- Produces: a concise final status with exact paths, hashes, device verdicts, rollback point, and the next authorized action.

- [ ] Verify all four gate outputs and deployment outputs from disk.
- [ ] Record any caveat such as unlock timeout separately from the typed business verdict.
- [ ] Update the checkpoint without rewriting unrelated completed stages.
