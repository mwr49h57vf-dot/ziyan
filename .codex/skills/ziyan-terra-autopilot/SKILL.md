---
name: ziyan-terra-autopilot
description: Use high-reasoning Codex work to advance ZiYan by one evidence-backed, reversible change per loop.
metadata:
  short-description: Advance ZiYan with one verified change per loop
  target-model: gpt-5.6-terra
  reasoning-effort: high
  cursor-source: .cursor/skills/ziyan-terra-autopilot/SKILL.md
---

# ZiYan Terra Autopilot

This is the project-level Codex mirror of `.cursor/skills/ziyan-terra-autopilot/SKILL.md`.
`AI_EXECUTION_PROTOCOL.md`, `ROADMAP.md`, and `DOCS/CURRENT_ISSUES.md` remain
the source of truth; this Skill adds no permissions, deployment authority, or
release gate.

## Required loop

1. Read the protocol, roadmap, current issues, current handoff, applicable
   device rules, and the narrowest relevant evidence.
2. Use CodeGraph `status`, `sync`, `query`/`explore`, `callers`, `callees`,
   `impact`, and `affected` for the touched symbol.
3. Classify one blocker, write one falsifiable hypothesis, one rollback point,
   one expected observation, and one stop condition.
4. Make one coherent, reversible change only after the impact review.
5. Run the narrowest local syntax, fixture, contract, package, and path checks.
6. For explicitly authorized device work, run only `.101 → .112 → .166 → .53 → .61`;
   stop on the first failure and roll back that device only.
7. Record changed files, commands, evidence, `FC_N`, `SB_CHG`, cleanup state,
   verdict, rollback, and exactly one next action.

## Project invariants

- `.149/.171` are read-only comparison devices; never deploy or write to them.
- Preserve `FC_N=1`, current-frame/front consistency, explicit keep-screen
  ownership, and stop cleanup.
- Never modify desktop `ios7.lua` or `ios8p.lua`.
- Do not add a competing supervisor or mask defects with SpringBoard/BackBoard
  restart, `sbreload`, or `killall`.
- A local check or historical package does not prove device PASS.
- After two ZiYan changes for the same classified symptom, obtain a read-only
  `.149/.171` comparison before a third implementation change.

## Delivery contract

```text
MODEL: gpt-5.6-terra / high
TASK: <one-line outcome>
BLOCKER_CLASS: <classification>
HYPOTHESIS: <one falsifiable sentence>
CHANGED_FILES: <paths>
LOCAL_CHECKS: <commands and results>
DEVICE_SCOPE: <devices or NOT_RUN>
AUTHORIZATION: <what was and was not authorized>
EVIDENCE: <paths or NONE>
VERDICT: PASS | CANDIDATE_PASS | INCONCLUSIVE | FAIL | BLOCKED | NOT_RUN | INVALID_RUN
ROLLBACK: <command, commit, package, or NONE>
NEXT_ACTION: <exactly one action>
```


## Compact handoff (overrides in-thread continuation)

If this turn is a compacted continuation summary, do not implement. Run
`python3 tools/ziyan_codex_emit_continuation_prompt.py --write`, then
`list_projects` + `create_thread` with that PROMPT. Stop this thread.
The user has explicitly requested successor threads. Do not `fork_thread`.

## Stream-resilient checkpoints

- Bound one implementation turn to one coherent 3–5 minute stage.
- Before more work, run `python3 tools/ziyan_codex_checkpoint.py show`; resume from `nextAction` when present.
- After every successful change/test stage, run `python3 tools/ziyan_codex_checkpoint.py write` with the literal last command/result, evidence path, and exactly one next action.
- Keep command output narrow (`rg`, `sed` ranges, summaries); never emit complete historical logs or the full CodeGraph.
- After a transport interruption, inspect the worktree and checkpoint first; do not repeat an already recorded successful modification.

## Codex two-thread tool contract

- First tool this turn: checkpoint `show` or CodeGraph MCP `codegraph_explore`.
- Prefer `codegraph_explore` over a `rg`/`sed` sweep of `current_frame`,
  `ZiYanFrameCapture`, or recovery adapter.
- Send stage feedback to「协助任务开发」with VERDICT path and SHA only.
- Do not poll dead thread `01a0499d-5293-7863-98fa-8d574d4173f6`.
- `.61` is an authorized primary acceptance device; use its rootless/mobile contract and
  do not treat a missing `.61` verdict as a complete main-plan gate.
