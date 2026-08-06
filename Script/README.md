# 子砚 Script SDK

用户可在本目录编写与学习自动化脚本。

| 目录 | 作用 |
|------|------|
| `Template/` | 可复制启动的脚本模板 |
| `Examples/` | 完整示例 |
| `Helper/` | 便捷封装（设计坐标 tap / 找色 / OCR） |
| `Debug/` | 调试辅助说明 |

**真相源**：`lua/modules/` 为 API 实现；`api_spec/` 为契约；`objc/` 为底层。

**坐标规则**：禁止 `Touch.tap(物理x,物理y)`。请使用：

```lua
Touch.atRatio(0.5, 0.7)          -- 比例
Touch.atDesign(568, 320)         -- 设计坐标（须 setDesign）
Touch.atHit(lx, ly)              -- 找色/OCR 命中点
```

`Helper.tap(x,y)` = **设计坐标**点击（等价 `Touch.tapDesign`），不是物理像素。
