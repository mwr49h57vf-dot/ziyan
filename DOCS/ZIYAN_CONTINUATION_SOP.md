# ZiYan 长上下文续接 SOP

本文件是 Codex 主任务的续接真值。与旧对话、压缩摘要冲突时，以磁盘 checkpoint 和本 SOP 为准。

用户已下令（覆盖压缩摘要里的「请在本对话继续」）：

1. 压缩后立刻停手，write checkpoint，把续接口令发给用户去新开 `ZiYan_副本` 对话粘贴。
2. 本机 AiMaMi 是 HTTP-only、不支持 Responses WebSocket v2。默认禁止 `create_thread` 开 worktree。
3. 新对话只执行 checkpoint 的唯一 `nextAction`。循环靠用户粘贴新对话，直到 `unfinished=false` 且 `nextAction` 为等待人工最终审核。
4. MCP / Skills / 本机 Agent 按 `DOCS/ZIYAN_MCP_SKILLS_AGENT_GUIDE.md` 调用。
5. 未压缩的第一回合禁止立刻再开空对话。

## 1. 什么叫「已经压缩」

出现任一情况，视为 compact，**禁止在本对话继续改代码、部署、跑真机**：

| 信号 | 含义 |
|---|---|
| 系统插入 `Another language model started to solve this problem and produced a summary...` | 历史已被摘要替换 |
| 本回合已出现 `compacted` 事件 | 同上 |
| `token_count.last_token_usage.input_tokens` ≥ `model_context_window` 的 65% | 即将再压一次，提前迁出 |
| 同一对话累计 compact ≥ 1 次后还要开新一轮长工具循环 | 直接迁出，不要再压 |

压缩摘要不是证据。禁止根据摘要宣称 DEVICE_PASS，禁止按摘要重做已写入 checkpoint 的成功步骤。

## 2. 压缩后必须做的顺序（硬顺序）

本对话剩下的唯一工作是交接，不是继续 `nextAction`。

```text
1. 停手：不再 exec 构建/部署/SSH，不再改 lua/objc。
2. python3 tools/ziyan_codex_emit_continuation_prompt.py --write
3. 用一行更新 今日项目进度.txt 的「默认首条助手动作」= 当前 nextAction。
4. 把脚本 PROMPT 原文发给用户。
5. 用户：Codex → 项目 ZiYan_副本 → 新任务 → 粘贴。cwd 必须是 /Users/mac/Desktop/ZiYan_副本，禁止 worktree。
6. 本对话停止。出现 call_id / previous_response_id / WebSocket v2 / 502 时同样走这条，不要重试。
```

checkpoint 写入：

```bash
python3 /Users/mac/Desktop/ZiYan_副本/tools/ziyan_codex_checkpoint.py write \
  --stage '<当前阶段>' \
  --last-command '<上一件已做成的命令>' \
  --result '<字面结果，含包 SHA / 设备状态>' \
  --next-action '<唯一下一步>' \
  --evidence '<VERDICT 或包路径>' \
  --latest-verdict '<DEVICE_PASS|DEVICE_INCONCLUSIVE|NOT_RECORDED|...>' \
  --package-version '<当前包版本>' \
  --package-sha256 '<当前包 SHA>' \
  --device-state '<四机状态>' \
  --running-processes '<LUA_N/FC_N/Z_N>' \
  --cleanup-status '<清场结果>'
```

必填语义：阶段、HEAD（脚本自动写）、已完成项、未完成项、最新 VERDICT、包 SHA-256、设备状态、唯一 `nextAction`、运行中进程、停止清理状态。

## 3. 如何新建对话继续任务

默认由用户手动新建，不要 `create_thread` 开 worktree。禁止 `fork_thread`。禁止自己占 `127.0.0.1:18080`。

```text
1. 仍必须先写完 checkpoint。
2. 把脚本 PROMPT 或 .codex/CONTINUATION_FIRST_MESSAGE.txt 打到回复里。
3. 用户在 Codex 侧边栏「新任务」选项目 ZiYan_副本，cwd=/Users/mac/Desktop/ZiYan_副本，粘贴为第一条消息。
4. 本对话停止。
```

不要用 `handoff_thread` 代替新建；不要向已压缩或已红（call_id/502）的对话续跑主线。

## 4. 新对话首条消息（磁盘模板）

新任务第一条必须来自：

`/Users/mac/Desktop/ZiYan_副本/.codex/CONTINUATION_FIRST_MESSAGE.txt`

该文件必须跟当前 checkpoint 同阶段。禁止长期停在「九号接棒任务 / 17-127 / 改 Chat.lua」。若 emit 正文与 checkpoint `stage`/`nextAction` 冲突，以 checkpoint 为准并改写模板。

新对话启动后自己再执行：

```bash
python3 tools/ziyan_codex_checkpoint.py show
```

然后只读：`今日项目进度.txt`、`ROADMAP.md`、`DOCS/CURRENT_ISSUES.md`、最新 `tmp_shots/**/VERDICT.md`、`DOCS/ZIYAN_MCP_SKILLS_AGENT_GUIDE.md`。只做 `nextAction`。

## 5. 状态冲突

优先级固定：

1. 当前设备端 final verdict
2. `DOCS/CURRENT_ISSUES.md`
3. `今日项目进度.txt`
4. checkpoint
5. 历史对话和压缩摘要

发现冲突先记 `STATE_MISMATCH`，对账后再改 checkpoint。不得重复已通过的设备阶段。
