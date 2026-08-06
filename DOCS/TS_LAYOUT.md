# 触动精灵执行路径学习 → 子砚布局

观察设备 `Media/TouchSprite` 习惯后，子砚自研布局（不拷贝触动二进制）：

## 可执行入口（仅此范围跑 C/OC/Lua/Python 业务脚本）
- `Media/ZiYan/*.lua|py|…`
- `Media/ZiYan/lua/`（保留，与根目录同等可执行）

## 数据与资源（归入 ZYCV）
| 用途 | 路径 |
|------|------|
| 选脚本 / 运行触发 / 分辨率引导 | `ZYCV/config/{select.lua,run.cfg,screen.cfg}` |
| 用户日志 | `ZYCV/log/ziyan.log` |
| 临时文件 | `ZYCV/tmp/` |
| 互通资源库 | `ZYCV/res/` |
| 截图 / OCR 缓存 | `ZYCV/` 根下 |

IPC 标志仍在 `usr/lib/ziyan/var`（不与用户 Media 混放）。
