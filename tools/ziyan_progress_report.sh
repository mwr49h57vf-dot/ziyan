#!/bin/bash
# 子砚 30 分钟进度报告支架（由 Agent 调用；不自动瞎写测试结果）
# 用法：tools/ziyan_progress_report.sh [序号]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
N="${1:-auto}"
TS=$(date '+%Y-%m-%d %H:%M:%S %z')
OUT="$ROOT/tmp_shots/REPORT_${N}_$(date '+%Y%m%d_%H%M').md"
mkdir -p "$ROOT/tmp_shots"
cat > "$OUT" << EOF
# 子砚项目进度报告

**时间：** $TS  
**说明：** 模板已生成；内容须由 Agent 根据真实执行填充，禁止编造测试结果。

## 1. 项目进度
- 当前阶段：
- 已完成：
- 进行中：
- 未完成：
- 阻塞：
- 下一步：

## 2. TouchSprite 学习
- .171 / .149：

## 3. 真机结果
- USB：
- LAN166：
- 未测项：明确列出

## 4. 函数变化
- 新增：
- 优化：

## 5. 屏幕同步
- 

## 6. 错误与清理
- 

## 7. 下一轮计划
- 
EOF
echo "$OUT"
