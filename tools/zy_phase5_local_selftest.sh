#!/bin/bash
# 阶段5 本地自检（不 SSH、不部署、不 killall SB）
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAIL=0
pass() { echo "[PASS] $*"; }
bad() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

SB=objc/tweak/springboard/ZiYanScreenBridge.m
FR=objc/tweak/framerelay/Tweak.m

# 1) 全文件无「[self pollColor]」调用（方法可保留但不得被 poll 调用）
if grep -n '\[self pollColor\]' "$SB" >/dev/null 2>&1; then
  bad "live [self pollColor] call remains"
else
  pass "no [self pollColor] calls"
fi
if grep -n '\[self pulseLongRunningStability\]' "$SB" >/dev/null 2>&1; then
  bad "live [self pulseLongRunningStability] call remains"
else
  pass "no [self pulse...] calls"
fi

# 2) pollColor 默认需 allow_sb_find
if grep -q 'ziyan_allow_sb_find' "$SB"; then
  pass "pollColor gated by allow_sb_find"
else
  bad "pollColor missing allow_sb_find gate"
fi

# 3) clearCachedPixelsForce 附近无 Clear 调用（仅注释可出现字样）
if python3 - <<'PY'
from pathlib import Path
t = Path("objc/tweak/springboard/ZiYanScreenBridge.m").read_text()
a = t.find("- (void)clearCachedPixelsForce {")
b = t.find("- (BOOL)isKeepScreenOn {", a)
body = t[a:b]
# strip // comments
import re
code = re.sub(r"//.*?$", "", body, flags=re.M)
raise SystemExit(0 if "ZiYanFrameShmClear(" not in code else 1)
PY
then
  pass "clearCachedPixelsForce keeps shm"
else
  bad "clearCachedPixelsForce still clears shm"
fi

# 4) relay 单飞 / nonce
grep -q 'sRelayBusy' "$SB" && pass "relay single-flight flag" || bad "relay single-flight missing"
grep -q 'relay_no_request_id' "$SB" && pass "relay requires nonce" || bad "relay nonce gate missing"

# 5) framerelay cold
grep -q 'ziyan_sb_cold_relay' "$FR" && pass "framerelay writes cold_relay" || bad "framerelay cold_relay missing"

# 6) Theos 编译
if make ZiYanVol ZiYanFrameRelay ziyan_framecap > /tmp/zy_p5_make.log 2>&1; then
  pass "make ZiYanVol FrameRelay framecap"
else
  bad "make failed"
  tail -40 /tmp/zy_p5_make.log || true
fi

# 7) shm 回归
if bash tools/ziyan_shm_selftest/run_host.sh > /tmp/zy_p5_shm.log 2>&1; then
  pass "shm host selftest"
else
  bad "shm selftest"
  tail -20 /tmp/zy_p5_shm.log || true
fi

echo "-----"
if [ "$FAIL" -eq 0 ]; then
  echo "ZIYAN_PHASE5_LOCAL=PASS"
  exit 0
fi
echo "ZIYAN_PHASE5_LOCAL=FAIL count=$FAIL"
exit 1
