# USB 811030b1ea917b3f754656361f7de66f6c21e0df
- deb: com.ziyan.ziyan_0.0.82-13+debug_iphoneos-arm64.deb (rootless)
- T1: PASS (App/Tweak/sb_alive/hooks)
- T2: PASS (round=1..3)
- T3: PASS (toast/mSleep/getColor/findMultiColor/dumpScreen/tap)
- T4: PASS
- T5: PASS (SB ack ok + usb_smoke rounds)
- note: getColor may return -1 if screen buffer empty; API callable
