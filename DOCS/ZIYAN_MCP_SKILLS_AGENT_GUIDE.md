# ZiYan MCP、Skills 与本机 Agent 指南

先查当前会话实际加载的工具名，再调用。禁止把旧 threadId / projectId 当永久资源。每次派发前：`list_projects` → `list_threads`。

## 1. 三层分别干什么

| 层 | 是什么 | 典型动作 | 不能当 |
|---|---|---|---|
| **MCP** | 当前 Codex/Cursor 会话里的外部工具 | 查线程、查调用链、联网、本机 HTTP | 四机 DEVICE_PASS |
| **Skill** | 磁盘上的 `SKILL.md` 工作流 | 先 Read 再按步骤做 | 授权书；读了不等于能部署 |
| **Agent** | 另一条 Codex 对话或本机 Local Agent | 审查、摘要、草稿 | 替代 `.101→.112→.166→.53` 结论 |

```text
识别场景 → 读对应 SKILL.md → 用对的 MCP → 需要旁路时 create_thread 派本机 Agent
→ 主任务只做 checkpoint.nextAction → 真机 VERDICT 才更新状态
```

## 2. MCP：当前机器上真实能调的

命名空间以会话里搜到的为准。ZiYan 规划对话里实际用过的是：

### A. `mcp__codex_app`（Codex 桌面，管任务）

| 工具 | 何时用 | 实测参数 | 禁止 |
|---|---|---|---|
| `list_projects` | 任何派发/新建之前 | `{}` | 缓存上周的 projectId |
| `list_threads` | 找「主任务进度」「协助任务开发」「本机agent」 | `{"limit":20}` | 用过期任务名当真值 |
| `create_thread` | **用户授权的新对话框**：compact 后续接主任务，或派本机旁路 | 先搜 schema；`projectId` 必须来自 `list_projects` | 当子 agent 滥用；`fork` 自己续主线 |
| `wait_threads` | 看协作任务有没有回 | `targets:[{threadId,hostId}]`；快照用 `timeoutMs:0` | 长超时轮询把本对话再压爆 |
| `send_message_to_thread` | 给**已有**协助任务发审查 | `{threadId,hostId,prompt}` | 往已压缩主线里续跑 nextAction |
| `read_thread` | 只读别人最后结论 | `{threadId,hostId,turnLimit:4~6,includeOutputs:false}` | 当进度轮询 |
| `fork_thread` | 仅用户明确要求「从某条已完成历史分叉」 | 先搜 schema | compact 后续接主任务（会带压缩摘要） |
| `set_thread_title` | 迁出后给旧对话加 `[已迁出]` | 先搜 schema | 用标题代替 checkpoint |

`create_thread` 异步。调用后必须 `wait_threads` 一次快照，并在回复里写 `::created-thread{threadId="..."}`。

Compact 后续接主任务：`projectId` = `ZiYan_副本`，`host=local`，prompt = `.codex/CONTINUATION_FIRST_MESSAGE.txt`。  
旁路审查：`projectId` = `本机agent`，禁止改 `/Users/mac/Desktop/ZiYan_副本`。

### B. `mcp__codegraph`（本机代码图）

| 工具 | 何时用 | 实测参数 |
|---|---|---|
| `codegraph_explore` | 改/查符号、调用链、影响范围 **之前** | `{"projectPath":"/Users/mac/Desktop/ZiYan_副本","query":"<符号或问题>","maxFiles":8}` |

禁止用十几次 `rg`/`sed` 扫 `current_frame` / `FrameCapture` / recovery。CodeGraph 不是 VERDICT。

### C. 本机执行与检索

| 能力 | 怎么调 | 边界 |
|---|---|---|
| shell / 构建 / 合同测试 | Codex `exec_command` 或 Cursor `Shell` | 部署四机需要现有授权；不清 `.149/.171` |
| 中文联网 | Skill `volcengine-search-web`（需环境变量） | 搜到的不能当 DEVICE_PASS |
| 通用网页 | 会话里的 fetch/search MCP（若已加载） | 同样不能当真机结论 |

未在本会话加载的 MCP 不要编造。先 tool search。

## 3. Skills：先读哪份

统一顺序：识别触发 → **Read `SKILL.md`** → 前置检查 → 单主题修改 → 验证 → 记证据。

### 主项目（cwd = `/Users/mac/Desktop/ZiYan_副本`）

| 触发 | 读这个 | 做什么 |
|---|---|---|
| 任何缺陷/打包/真机/API/交接 | `.codex/skills/ziyan-verdict-loop/SKILL.md` | 四机顺序、清场、VERDICT、回滚 |
| 单刀改动 + checkpoint | `.codex/skills/ziyan-terra-autopilot/SKILL.md` | 一回合一主题，write checkpoint |
| compact / 上下文过长 / 交接摘要 | `AGENTS.md` + `.codex/skills/ziyan-compact-handoff/SKILL.md` | 停手、`ziyan_codex_emit_continuation_prompt.py --write`、`create_thread`；再压缩再迁出 |
| Bug / 测试失败 | `/Users/mac/.agents/skills/systematic-debugging/SKILL.md` | 先复现再改 |
| 准备宣称完成 | `/Users/mac/.agents/skills/verification-before-completion/SKILL.md` | 先跑验证再说话 |
| 已有书面计划要逐步落地 | `/Users/mac/.agents/skills/executing-plans/SKILL.md` | 按计划一刀 |
| 看截图 / OCR | `.codex/skills/vision-ai/SKILL.md` | 本地 `vision_ai.py`；缺 `llm_config.py` 则停，不擅自下权重 |
| 触动手册 / 协议 / 二进制只读 | `.codex/skills/reverse-engineering-analyst/SKILL.md` | 只分析；实现落 `lua/` `objc/`；禁止链 TS dylib |
| 中文「搜一下」 | `.codex/skills/volcengine-search-web/SKILL.md` | 无 API key 则停，不编造 |
| 安装外来 skill 前 | `.codex/skills/skill-scanner/SKILL.md` | 只出报告，不自动删 |
| trace / OpenTelemetry 文档 | `.codex/skills/trace/SKILL.md` | 跑 helper，不发明文档 |

### 旁路项目（cwd = `/Users/mac/Desktop/本机agent`）

| 触发 | 读这个 | 做什么 |
|---|---|---|
| 本地模型 / Local Agent 能做什么 | `.codex/skills/local-offline-agent/SKILL.md` | 只走本机 llama-server |
| 在本机agent 树里查代码 | `.codex/skills/codegraph-mcp/SKILL.md` | `projectPath` 指向本机agent |

## 4. 本机可以叫哪些 Agent

这里的 Agent = **另一条对话或本机进程**，不是 MCP 函数名。

### 4.1 两个项目（物理目录）

| 项目名 | 路径 | Git | 谁在里面干活 | 允许 | 禁止 |
|---|---|---|---|---|---|
| **ZiYan_副本** | `/Users/mac/Desktop/ZiYan_副本` | 是 | 主任务 Codex | 改 `lua/` `objc/` `tools/`、构建、四机部署、写 VERDICT | 改桌面 `ios7.lua`/`ios8p.lua`；部署 `.149/.171` |
| **本机agent** | `/Users/mac/Desktop/本机agent` | 否 | 旁路 Codex + Local Agent.app | 静态审查、日志摘要、报告草稿、拉起 `127.0.0.1:18080` | 改 ZiYan 源码、`dpkg`、SSH 四机、写 DEVICE_PASS |

派发本机agent：

```text
list_projects → cwd=/Users/mac/Desktop/本机agent 的 projectId
create_thread（host=local）
首条消息必须包含：不要改 /Users/mac/Desktop/ZiYan_副本，不要部署，不要 SSH 四机。
结果用 send_message_to_thread 打回当前主任务 threadId（现查，不写死旧 ID）。
```

旁路原文模板见 `DOCS/LOCAL_LLM_COLLAB_SOP.md`。回传 ID 每次现查，禁止再写死 `thread://01a05fec-...`。

### 4.2 本机已有 Codex 对话（名称会变，以 list_threads 为准）

| 常见标题 | 角色 | 怎么协作 | 不能做 |
|---|---|---|---|
| 当前 ZiYan 续接对话 | **唯一执行 nextAction 的写入者** | 本对话 | 压缩后还继续干 |
| `主任务进度` | 路线/阶段协调（若仍存活） | `wait_threads` 快照或短 `send_message_to_thread` | 轮询 `read_thread`；把旧 ID `01a0499d-...` 当活任务 |
| `协助任务开发` | 只读复核假设、补丁、证据 | `send_message_to_thread`，附 VERDICT 路径和 SHA | 未经用户点名就放行设备 |
| 标题含本机agent / 旁路 | 本地分析 | `create_thread` 到本机agent 项目 | 占用主任务去跑 llama-server |

历史 ID 只作考古，不作调用参数：

- 已死/勿轮询：`01a0499d-5293-7863-98fa-8d574d4173f6`
- 旧规划（已 502 停）：`01a05fec-8393-7930-aad6-ed373be9abd8`

### 4.3 本机进程（不是 Codex 对话）

| 进程 | 地址 / 路径 | 谁启动 | 用途 | 不能当 |
|---|---|---|---|---|
| `llama-server` | `http://127.0.0.1:18080/health` 与 `/completion` | **本机agent 旁路对话**启动；主任务禁止自己占 18080 | `coder`/`fast`/`deep`/`r1` 短补全 | 四机 PASS |
| Local Agent.app | `/Users/mac/Desktop/本机agent/Local Agent.app` | 用户或旁路 | 本机离线 agent UI | 越狱部署 |
| 权重 | `~/Library/Application Support/local-offline-agent/models/` | 已在磁盘 | GGUF，一次只跑一个（8GB 默认 `coder`） | 并行四模型 |

健康检查：`curl -sS -m 2 http://127.0.0.1:18080/health` 必须 HTTP 2xx。`Loading model` / 503 不算 ready。细节：`DOCS/LOCAL_LLM_COLLAB_SOP.md`。

## 5. 分工（写死）

```text
ZiYan_副本 当前对话
  └── 唯一写入者：构建、部署、.101→.112→.166→.53、最终 VERDICT、更新 checkpoint

compact 一旦发生
  └── 本对话停手 → write checkpoint → create_thread(ZiYan_副本) → 用户改跟新对话

协助任务开发
  └── 独立复核；不改 nextAction；不部署

本机agent 旁路对话
  └── 静态审查 / 18080 补全 / 报告草稿
  └── 禁止改 ZiYan、装包、SSH、写 DEVICE_PASS

llama-server:18080
  └── 本机小模型，开发证据 only
```

## 6. 本机 Agent 派发验收（强制）

旁路结束必须能勾这五项，否则当无效：

- 没有改 `/Users/mac/Desktop/ZiYan_副本` 源码
- 没有 `dpkg` / scp 装包
- 没有 SSH `.53/.101/.112/.166/.149/.171`
- 没有把本地结论写成 DEVICE_PASS
- 没有改 `checkpoint.nextAction`
