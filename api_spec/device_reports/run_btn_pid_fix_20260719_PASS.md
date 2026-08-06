# App Run pid-invalid fix PASS

- Package: 0.0.81-27+debug
- Error fixed: 内置 Lua 未存活（pid 无效）
- Fix: App 经 `.ziyan_sb_run_req` 由 SpringBoard 代启 lua5.3

## Auto evidence
- app_run_trig → run_ok
- go_home + background_ok, FG=0
- round=6, PID_ALIVE=1
- ACCEPT=PASS

## Manual
1. 打开 ZiYan，勾选脚本（如 login_xztl.lua）
2. 点导航栏 Play 或音量菜单「运行」
3. 应「已启动」并回桌面，脚本继续跑（不再提示 pid 无效）
