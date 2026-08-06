# 子砚 SDK 文档系统

## 生成

```bash
python3 tools/ziyan_doc/generate_html.py
```

输出：

- `/Users/mac/Desktop/ZiYan_副本/子砚触控函数说明.html`
- `tools/ziyan_doc/api_catalog.json`（权威函数目录）
- `tools/ziyan_doc/CHANGELOG.jsonl`（新增/修改/废弃流水）
- `tools/ziyan_doc/SYNC_REPORT.json`（与代码差异）

## 规则

1. **新增函数**：在 `lua/modules/*.lua` 增加 `function M.xxx` 后重新生成 → 自动入 catalog。
2. **修改函数**：在 catalog 对应条目的 `changelog` 写：`before/reason/after/test`，再生成。
3. **废弃函数**：设 `status=deprecated`，填 `deprecated_reason` / `replacement` / `migration`。
4. **待完善**：设 `status=planned`（如 swipe/longPress）。

禁止手改 HTML 为主；以 catalog + 生成器为准。
