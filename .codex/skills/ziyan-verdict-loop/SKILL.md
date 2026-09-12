---
name: ziyan-verdict-loop
description: Run ZiYan’s evidence-first delivery loop for fixes, compatibility work, packaging, device validation, API contracts, and handoff.
metadata:
  short-description: Choose one evidence-backed next action
  cursor-source: .cursor/skills/ziyan-verdict-loop/SKILL.md
---

# ZiYan Evidence Loop

This is the project-level Codex mirror of `.cursor/skills/ziyan-verdict-loop/SKILL.md`.
It is an adapter for `AI_EXECUTION_PROTOCOL.md`; it adds no permissions,
device access, or release gates.

## Start

0. If this turn contains a compaction summary, stop product work and follow
   `AGENTS.md` / `.codex/skills/ziyan-compact-handoff/SKILL.md` (`create_thread`).
   Do not preflight or continue `nextAction` in a compacted thread.
1. Run the existing local preflight:
   `bash .cursor/skills/ziyan-verdict-loop/scripts/preflight.sh`.
2. Read `AI_EXECUTION_PROTOCOL.md`, `ROADMAP.md`, `DOCS/CURRENT_ISSUES.md`,
   the current handoff, relevant evidence, and only the files needed for the
   observed symptom.
3. Run focused CodeGraph review before changing a source or control file.

## Choose exactly one next action

| Observation | Required action |
|---|---|
| Channel, package, script hash, or test record unavailable | Diagnose the channel; do not modify product behavior. |
| No device-side terminal artifact | Recover evidence or cleanly stop; do not write PASS or FAIL. |
| Classified gate failure | Change one owning layer: capture, front/lease, matching, touch, lifecycle, or API contract. |
| Same symptom after two ZiYan changes | Gather `.149/.171` read-only comparison evidence. |
| API is partial or planned | Add contract fixture, implement one family, then validate rootful and rootless. |

## Boundaries

- Valid ZiYan device order is `.101 → .112 → .166 → .53 → .61`.
- `.61` is mandatory for the iOS 15.8.8 rootless compatibility verdict.
- `.149/.171` are comparison-only and never receive writes or deployments.
- Never touch `ios7.lua`, `ios8p.lua`, `LOCK_*`, or C1 path branches without a
  written change request and the protocol-required evidence.
- No SpringBoard/BackBoard restart, `sbreload`, or `killall`.
- Maintain `FC_N=1`, `SB_CHG=0`, and explicit stop cleanup on all five acceptance devices.

## Close each loop

Create or update the evidence record with command exit status, hashes, device
state, `FC_N`, `SB_CHG`, cleanup state, rollback point, and one next action.
Only promote status when the current `ROADMAP.md` gate and current evidence
permit it.

## Codex supervisor / executor tool contract

Use this section in the「协助任务开发」and「主任务进度」threads.

1. First command: `python3 tools/ziyan_codex_checkpoint.py show`. If the
   desktop file is missing, read
   `/Users/mac/.codex/worktrees/edf5/ZiYan_副本/.codex/ZIYAN_ACTIVE_CHECKPOINT.json`.
2. Resume only `nextAction`. Do not repeat a recorded successful stage.
3. Follow「主任务进度」with `wait_threads` (`timeoutMs: 0` snapshot). Do not
   `read_thread` or `read_mcp_resource` poll
   `thread://01a0499d-5293-7863-98fa-8d574d4173f6`.
4. Review call chains with the CodeGraph MCP (`codegraph_explore`). Do not
   reconstruct `AgentAutonomousEngine` / lease / `request_id` with `rg`/`sed`.
5. Review only the current `VERDICT.md` plus SHA. Do not rerun already
   recorded local tests. Local contract PASS is not DEVICE_PASS.
6. GitHub search is read-only open-source contrast only. Never treat it as a
   ZiYan device verdict. Keychain stays `SUSPENDED` unless the user reopens it.
