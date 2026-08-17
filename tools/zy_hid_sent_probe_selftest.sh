#!/bin/bash
# ScreenBridge .ziyan_hid_sent 诊断埋点静态合同。不 SSH、不部署。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SB=objc/tweak/springboard/ZiYanScreenBridge.m
FAIL=0
pass() { echo "[PASS] $*"; }
bad() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

grep -q 'ZiYanHidSentTraceOnce' "$SB" && pass "probe helper present" || bad "probe helper missing"
grep -q 'ziyan_hid_sent' "$SB" && pass "writes .ziyan_hid_sent" || bad "hid_sent path missing"
grep -q 'sWroteSession' "$SB" && pass "once-per-session guard" || bad "once-per-session missing"
grep -q 'dispatch_async' "$SB" && pass "async write" || bad "async write missing"
if grep -n 'sysctlbyname' "$SB" >/dev/null; then
  bad "sysctlbyname still in ScreenBridge"
else
  pass "no sysctlbyname"
fi
if grep -n '__attribute__((constructor))' "$SB" >/dev/null; then
  bad "constructor in ScreenBridge"
else
  pass "no constructor in ScreenBridge"
fi
grep -q 'request_id=' "$SB" && pass "request_id field" || bad "request_id missing"
grep -q 'error_code=' "$SB" && pass "error_code field" || bad "error_code missing"
grep -q 'front_bundle=' "$SB" && pass "front_bundle field" || bad "front_bundle missing"
grep -q 'target_bundle=' "$SB" && pass "target_bundle field" || bad "target_bundle missing"

# 不得改 HID 调用参数
if python3 - <<'PY'
from pathlib import Path
t = Path("objc/tweak/springboard/ZiYanScreenBridge.m").read_text()
a = t.find("if (skipSBUI) {")
b = t.find("return;", a)
block = t[a:b]
need = [
    "injectNormPhase:phase",
    "finger:(int)idx",
    "nx:nx",
    "ny:ny",
    "skipHand:YES",
]
ok = all(s in block for s in need)
# 埋点必须在 inject 之后、return 之前
ok = ok and "ZiYanHidSentTraceOnce(phase, hidSent)" in block
raise SystemExit(0 if ok else 1)
PY
then
  pass "skipSBUI HID call unchanged; probe after inject"
else
  bad "skipSBUI HID call or probe order changed"
fi

# 禁止高频：不得在非 up / 无 learn_active 时写
if grep -A2 'ZiYanHidSentTraceOnce' "$SB" | grep -q 'isEqualToString:@"up"'; then
  pass "write gated on phase=up"
else
  # helper 内检查
  grep -q 'isEqualToString:@"up"' "$SB" && pass "write gated on phase=up" || bad "missing up gate"
fi
grep -q 'ziyan_agent_learn_active' "$SB" && pass "write gated on learn_active" || bad "learn_active gate missing"

echo "-----"
if [ "$FAIL" -eq 0 ]; then
  echo "ZIYAN_HID_SENT_PROBE=PASS"
  exit 0
fi
echo "ZIYAN_HID_SENT_PROBE=FAIL count=$FAIL"
exit 1
