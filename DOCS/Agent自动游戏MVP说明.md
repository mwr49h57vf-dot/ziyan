# Agent 自动游戏 MVP

CLOCK_SKEW=device_2026-08-16_actual_2026-08-15

本地规则状态机。不接 Ollama / iOS-MCP / 云端模型。不新增守护。

音量减：普通 Lua/Python。音量加：Agent 运行则停止，否则 toast 已配置列表。

敏感页（密码、验证码、支付、交易等）→ `PAUSED_SAFE`，不绕过。

生成脚本只放 `Agent游戏/生成脚本/`，只许调用已验证 ZiYan API。

不得宣称完全兼容或超越触动。
