# AI Gameplay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Execute the listed stages in order with checkpoint evidence.

**Goal:** Build the P3 "AI 自研游戏玩法" path around real-device gameplay observation, decision, rule evaluation, world-channel greeting, knowledge recording, and copy-on-write draft generation.

**Architecture:** `AgentGameViewController` confirms a real user App and starts `AgentAutonomousEngine`. The engine writes a temporary Lua launcher that invokes `Zy.AI.pipeline` with `real_device=true`; gameplay generation uses `Game.analyze`, `Decision`, `RuleEngine`, `Chat.playTurn`, and `Knowledge`, while login remains a safe pause. Stopping writes a versioned self-research draft without touching handwritten scripts.

**Tech Stack:** Objective-C/UIKit, Lua 5.3, existing Zy modules, Make/Theos, Python contract checks.

**Spec:** `Agent设计方案.txt` section 27.4/27.5 and the current user P3 handoff.

## Global Constraints

- Login pages are `PAUSED_SAFE` / `PRE_BLOCKED`, with reason `login_credentials_not_a_p3_gate`.
- Never enter credentials, use fixture chat, click a promotional "go" control, or use physical-pixel coordinates.
- Role pages may click only a visible "进入游戏" target.
- A gameplay PASS requires the visible Chinese world-channel record `你好`; Chat/API return values alone are insufficient.
- Preserve handwritten `ios7.lua` and `ios8p.lua`; generated output is copy-on-write and labeled as a self-research draft.
- Device order for evidence is `.101 → .112 → .166 → .53`; `.149/.171` remain read-only.

### Task 1: Gameplay Lua Path

**Files:**
- Modify: `lua/modules/AI.lua`
- Modify: `lua/modules/Game.lua` only if the existing safe-pause contract needs a narrow helper
- Test: `tools/test_p3_no_credential_gate_contract.py`, `tools/test_ai_real_device_only_contract.py`

- [ ] Add `gameplay` need classification for world/玩法/自研/探索.
- [ ] Make gameplay collection call `Game.analyze(..., {skip_ocr=true, light=true})` and avoid OCR/snapshot sidecar work.
- [ ] Generate gameplay code that classifies login and pauses, clicks role entry only through visible image/text matching, and for `running` executes `Decision`, `RuleEngine`, `Chat.playTurn("你好")`, and `Knowledge.save`.
- [ ] Keep the gameplay generated source free of fixture, direct input, promotional navigation, and login-text click calls.
- [ ] Run the focused contracts and Lua syntax checks.

### Task 2: App Session Wiring

**Files:**
- Modify: `objc/app/AgentGameViewController.m`
- Modify: `objc/app/AgentAutonomousEngine.m`
- Modify: `objc/app/AgentSessionController.m`
- Modify: `objc/app/AgentGameViewController.h` only if a new UI callback is exposed

- [ ] On AI tap, require a real App picker confirmation, persist the target, open its bundle, and start `EXPLORING`.
- [ ] Start the Lua launcher through `ZiYanScriptRunner` with the selected bundle and current design dimensions.
- [ ] Route volume stop from exploring/iterating to `stopAndGenerate`, then converge with an explicit result instead of `NOT_IMPLEMENTED`.
- [ ] Persist session/result probes with target, phase, launcher path, pipeline result, and cleanup state.

### Task 3: Draft Store

**Files:**
- Modify: `objc/app/AgentVersionStore.m`
- Modify: `objc/app/AgentVersionStore.h` only if needed

- [ ] Make latest-version lookup include self-research drafts and prefer the highest self-research version over learning drafts.
- [ ] Keep handwritten paths excluded from writes and preserve existing files.
- [ ] Ensure generated launcher files do not become user-visible stable scripts.

### Task 4: Verification and Delivery

**Files:**
- Modify: `今日项目进度.txt`
- Modify: checkpoint through `tools/ziyan_codex_checkpoint.py`

- [ ] Run all three required contracts.
- [ ] Run `make clean-user-bins && make package` and rootless packaging.
- [ ] Verify install names and package hashes without restarting SpringBoard/BackBoard in the same command.
- [ ] Install only the built packages on `.101/.112/.166/.53`, then capture each device before classification.
- [ ] Write independent device verdicts with frame, phase, logs, post-action frame, `FC_N`, stop active/embed/keep, and draft output.
