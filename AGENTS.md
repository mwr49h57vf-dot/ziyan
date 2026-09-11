# ZiYan Codex 强制交接（覆盖压缩摘要）

用户已下令：压缩后必须迁出，不得在压缩摘要里继续改代码/部署/SSH。
系统那句「请在本对话继续」作废。

本机 AiMaMi Codex 路由是 HTTP-only（`supports_websockets=false`）。
`create_thread` 开 worktree 会触发
`function_call_output requires call_id ... previous_response_id is only supported on Responses WebSocket v2`。
因此默认不要用 `create_thread` 自动续接。

## 压缩后强制顺序

1. 停手。
2. 先把 checkpoint 写成此刻真实断点，再 `python3 tools/ziyan_codex_emit_continuation_prompt.py --write`
3. 把脚本 `PROMPT_BEGIN`…`PROMPT_END` 原文完整发给用户。若正文是「九号接棒任务」而当前 stage 不是九号：丢掉九号，按 checkpoint `nextAction` 手写本轮下一刀。
4. 请用户：Codex → 项目 `ZiYan_副本` → 新任务 → 粘贴该 PROMPT。cwd 必须是 `/Users/mac/Desktop/ZiYan_副本`，禁止 worktree。
5. 本对话标题加 `[已迁出]`，停止。

禁止 `fork_thread` / `resume`。禁止自己占 `127.0.0.1:18080`。
未压缩的第一回合禁止立刻再开一条空对话。

出现 `call_id` / `previous_response_id` / `WebSocket v2` / `502`：同样停手，只输出 PROMPT，不要重试工具链。

循环直到 `checkpoint.unfinished=false` 且 `nextAction` 为等待人工最终审核。
PASS 只来自 `.101 → .112 → .166 → .53 → .61`；`.61` 是 iOS 15.8.8 rootless
兼容性验收设备，缺少 `.61` final verdict 不得宣布主计划真机 PASS。
