# [LAN] 图色验收 2026-07-20

- Package: `com.ziyan.ziyan_0.0.82-19+debug_iphoneos-arm`
- Device: 192.168.31.166 / rootful
- Same `login_xztl.lua` (absolute 2111,549)

## Probe
```
screen=1136,640 color@2111,549=<clamped> find_b9271b=-1,-1
src=640x1136 logicBuf=1136x640 scale=2 init=1 rot=1
```

## Exact script path (2 loops)
```
时间:… 点:-1,-1
OCR:BHm / Eo  (region has text; OCR path OK)
```

## Verdict
- **Orient/buf sync PASS** on LAN (1136×640 after init(1))
- **Find `-1` expected**: script coords are Plus@3x landscape (`2111` > `1136` width); not a USB-only bug
