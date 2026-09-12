---
name: ziyan-compact-handoff
description: REQUIRED on Codex compact, continuation summary, 上下文压缩, call_id, previous_response_id, or WebSocket v2 errors. Stop product work, write checkpoint, emit paste prompt. Do not create_thread worktrees on this HTTP-only AiMaMi router.
---

# ZiYan Compact → 人工粘贴新对话

本机 AiMaMi 路由不支持 Responses WebSocket v2。不要 `create_thread` 开 worktree。

1. 读 `AGENTS.md`。
2. 先把 checkpoint 写成此刻真实断点，再跑（不要用 compact-handoff 覆盖 last-command / result）：

```bash
python3 tools/ziyan_codex_emit_continuation_prompt.py --write
```

3. `SPAWN_REQUIRED=0`：告诉用户等待人工审核。
4. `SPAWN_REQUIRED=1`：把 `PROMPT` 原文发给用户，请其在 Codex 项目 `ZiYan_副本` 新建任务粘贴。cwd 必须是桌面仓库，禁止 worktree。PROMPT 必须是当前 stage / nextAction，禁止 go_home，**登录页安全暂停，禁止填写账号密码**。若 PROMPT 出现「九号接棒任务」或「改 Chat.lua」而当前 stage 不是九号：丢掉该正文，按 checkpoint 手写下一刀。不得把 nextAction 缩回只诊断 no_message，也不得缩回九号 Chat 打包。
5. 本对话停止。

禁止 `fork_thread`。禁止把压缩摘要当 DEVICE_PASS。
