# LAN 192.168.31.166

- deb: `com.ziyan.ziyan_0.0.82-14+debug_iphoneos-arm.deb` (rootful)
- SSH: `root@192.168.31.166:22`；密码优先 `ZIYAN_SSH_PASS`，否则工程习惯值 `alpine`
- T1: PASS（App/Tweak/sb_alive/hooks）
- T2: PASS（round=1..3）
- T3: PASS（toast/mSleep/getColor/findMultiColor/dumpScreen/tap）
- T4: PASS
- T5: PASS（SB ack ok + usb_smoke rounds）
