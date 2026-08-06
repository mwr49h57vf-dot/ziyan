# [USB] 图色验收 2026-07-20

- Package: `com.ziyan.ziyan_0.0.82-18+debug_iphoneos-arm64`
- Device: iPhone10,2 / iOS16.7.16 / rootless `/var/jb`
- Fix: logic size = buffer (`2208×1242`), `.ziyan_buf_wh` sync, black-frame retry

## Probe
```
screen=2208,1242 color@2111,549=0xCA0304 find_b9271b=-1,-1 find_live=2111,549
src=1242x2208 logicBuf=2208x1242 scale=3 init=1 rot=1
```

## Exact login_xztl.lua path (2 loops)
```
时间:… 点:-1,-1
OCR无结果
```

## Verdict
- **Pipeline PASS**: init/getScreenSize/getColor/findMultiColor(live) OK
- **Script color@90**: `-1` because live pixel `0xCA0304` vs target `0xb9271b` exceeds degree-90 tolerance (GΔ≈36 > tol≈25.5)
