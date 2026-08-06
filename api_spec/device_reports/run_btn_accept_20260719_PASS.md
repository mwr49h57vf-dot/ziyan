# Run button accept PASS

- Device: 192.168.31.166
- Package: com.ziyan.ziyan_0.0.81-25+debug_iphoneos-arm.deb
- Script: /private/var/mobile/Media/ZiYan/_ziyan_run_btn_test.lua
- Trigger: `.ziyan_app_run_trig` ≡ `runButtonTapped` + minimize

```
sb open_app launchIdentifier=com.ziyan.ziyan ok=1
fg→1
TRIG
round=5
PID_ALIVE=1
FG=0
path=go_home_req + sb go_home via SpringBoard _simulateHomeButtonPress
path=background_ok
OK_ROUND=1 OK_MIN=1
ACCEPT=PASS
```

## Manual steps
1. 打开 ZiYan
2. 勾选 `_ziyan_run_btn_test.lua`（或任意 .lua）
3. 点导航栏 Play
4. 应 toast「已启动」后回桌面，脚本继续跑
5. 再打开 App 点 Play 应停止
