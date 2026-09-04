# 本地大模型旁路协作（不中断主任务）

给 ZiYan 主任务 Codex 对话用（当前续接对话标题以 `list_threads` 为准，不写死旧 ID）。本文件只增加旁路能力，**不得改 checkpoint.nextAction，不得把主任务对话改成 llama-server 操作员。**

主任务一旦 compact，走 `DOCS/ZIYAN_CONTINUATION_SOP.md` 新建对话；旁路仍派发到项目 `本机agent`，不要 fork 主任务。

当前不得改动的 nextAction：

```text
以 `python3 tools/ziyan_codex_checkpoint.py show` 返回的唯一 `nextAction`
为准；不得引用过期包版本或旧任务 ID。
```

## 原则

1. 本对话继续规划/编排，当前 nextAction 做完再读下一件。
2. 本地 GGUF **一次只跑一个**（这台 8GB Intel，默认 `coder`）。
3. 用 `create_thread` / `send_message_to_thread` 拉**旁路助手**，不要 `resume` 自己、不要 `fork` 自己、不要 `exec resume` 本 thread。
4. 本地 `/completion` 结果只算开发证据，**不能**当四机功能 PASS。
5. 未过 G0 / 四机 VERDICT，禁止写「已全面超越触动」。

## 权重位置（不在源码树）

目录：`/Users/mac/Library/Application Support/local-offline-agent/models/`

| 键 | 文件 | 旁路用途 |
|---|---|---|
| `coder` | `deepseek-coder-1.3b-instruct-q4_k_m.gguf` | **默认。** 小补丁草稿、JSON 工具调用、短日志摘要 |
| `fast` | `qwen2.5-coder-1.5b-instruct-q4_k_m.gguf` | 快速分类、失败归类、短审查 |
| `deep` | `qwen2.5-coder-3b-instruct-q4_k_m.gguf` | 较长静态审查；切之前必须先停旧 server |
| `r1` | `deepseek-r1-distill-qwen-1.5b-q4_k_m.gguf` | 决策/重试策略草稿，不写设备、不改 HID |

`llama-server`：`/Users/mac/Library/Application Support/local-offline-agent/llama/bin/llama-server`  
探测：`curl -sS -m 2 http://127.0.0.1:18080/health`（HTTP 2xx 才算 ready；`Loading model` / 503 不算）

## 旁路拉起（本对话只发指令，自己不占 18080）

默认 8GB 用 `coder`：

```bash
BIN="/Users/mac/Library/Application Support/local-offline-agent/llama/bin/llama-server"
MODEL="/Users/mac/Library/Application Support/local-offline-agent/models/deepseek-coder-1.3b-instruct-q4_k_m.gguf"
curl -sS -m 2 -o /dev/null -w "%{http_code}" http://127.0.0.1:18080/health | grep -q '^2' || \
"$BIN" -m "$MODEL" --host 127.0.0.1 --port 18080 -c 2048 -t 4 -np 1 -b 256 -ub 128
```

调用：

```bash
curl -sS http://127.0.0.1:18080/completion \
  -H 'content-type: application/json' \
  --data '{"prompt":"...","n_predict":280,"temperature":0.2,"cache_prompt":true}'
```

切 `deep` / `r1` / `fast` 前：先停 18080 上的旧进程，再换 `-m`。禁止四模型并行。

## 分工（旁路，不抢主线）

```text
剩余项目进度规划（本对话）
  └── 继续当前 nextAction；只编排，不自己跑本地推理

主任务进度 / ZiYan_副本写入者
  └── 构建、部署、.101→.112→.166→.53、最终 VERDICT

协助任务开发
  └── 复核假设、代码影响、证据、回滚；不放行设备除非用户点名

本机agent 旁路助手（create_thread，cwd=/Users/mac/Desktop/本机agent）
  └── 拉起/复用 18080，做静态审查、日志摘要、报告草稿
  └── 结果只回本对话或协助任务开发；禁止改 ZiYan 源码、禁止装包、禁止碰四机
```

## 本对话应立刻做的唯一旁路动作

做完或并行于当前 nextAction 时，**只** `create_thread`（项目选 `本机agent`，host=local），第一条消息用下面原文。不要 fork 本对话，不要改 nextAction。

```text
旁路任务，禁止中断 ZiYan 主任务，禁止改 checkpoint.nextAction。
项目：/Users/mac/Desktop/本机agent
不要改 /Users/mac/Desktop/ZiYan_副本 源码，不要部署，不要 SSH 四机。

1. curl -sS -m 2 http://127.0.0.1:18080/health
2. 若未 ready：用 Application Support 里的 llama-server 拉起 coder（deepseek-coder-1.3b-instruct-q4_k_m.gguf），-c 2048 -t 4 -np 1 --port 18080
3. 只对只读材料做本地补全：checkpoint、今日项目进度、最新 VERDICT、LOCAL_LLM_COLLAB_SOP.md
4. 产出：一份短报告（风险、建议 nextAction 候选、未验证项）。本地结论不得写成 DEVICE_PASS。
5. 先 list_threads 找到当前 ZiYan 主任务 threadId/hostId，再用 send_message_to_thread 发回。禁止写死旧 thread:// ID。
完成后本助手停在待命，不要继续扩 scope。
```

## 回传格式（给规划对话）

```text
本地模型：coder|fast|deep|r1
18080：ready|missing
只读了哪些文件
建议（候选，不是命令）
明确未验证
没有改 ZiYan 源码 / 没有装包 / 没有碰四机
```
