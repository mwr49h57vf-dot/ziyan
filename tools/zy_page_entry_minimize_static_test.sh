#!/usr/bin/env bash
# Local static + decision tests for page-entry minimize. No device, no package.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAIL=0
say() { echo "$*"; }
bad() { echo "FAIL: $*"; FAIL=1; }
ok() { echo "PASS: $*"; }

APP="$ROOT/objc/app/ceshiRootViewController.m"
HDR="$ROOT/objc/app/ZiYanPageEntryMinimize.h"
OV="$ROOT/objc/app/OverlayWindow.m"
RUNNER="$ROOT/objc/shared/ZiYanScriptRunner.m"

say "== decision unit test =="
cc -std=c99 -Wall -Wextra -Werror -o /tmp/zy_page_min_dec \
  "$ROOT/tests/page_entry_minimize_decision.c"
/tmp/zy_page_min_dec

say "== page minimize helpers must not force-hang or respring =="
if rg -n 'NSSelectorFromString\(@"suspend"\)|objc_msgSend.*sus|sbreload|ldrestart|killall SpringBoard|killall backboardd' \
    "$HDR" "$APP"; then
  bad "forbidden API in page minimize sources"
else
  ok "no suspend selector / sbreload / ldrestart / killall SB-BB in helper+controller"
fi

# The page-entry function body itself
if python3 - <<'PY'
import pathlib, re, sys
p = pathlib.Path("objc/app/ceshiRootViewController.m").read_text()
m = re.search(r"static BOOL ZiYanPageEntryMinimizeOnce\(NSString \*entry\) \{.*?\n\}", p, re.S)
if not m:
    print("FAIL: cannot find ZiYanPageEntryMinimizeOnce")
    sys.exit(1)
body = m.group(0)
bad = []
for tok in ("suspend", "sbreload", "ldrestart", "killall", "exit(", "kill("):
    if tok in body:
        bad.append(tok)
if bad:
    print("FAIL page-entry body contains:", ", ".join(bad))
    sys.exit(1)
if "ZiYanRequestAppMinimizeAfterScriptStart" not in body:
    print("FAIL page-entry missing single request helper")
    sys.exit(1)
if body.count("ZiYanRequestAppMinimizeAfterScriptStart") != 1:
    print("FAIL page-entry must request exactly once")
    sys.exit(1)
print("PASS page-entry body: one request, no forbidden tokens")
PY
then
  ok "page-entry function contract"
else
  bad "page-entry function contract"
fi

say "== callers of ZiYanPageEntryMinimizeOnce =="
CALLS=$(rg -n 'ZiYanPageEntryMinimizeOnce\(' "$ROOT/objc" "$ROOT/lua" || true)
echo "$CALLS"
if echo "$CALLS" | rg -q 'OverlayWindow'; then
  bad "volume OverlayWindow must not call page minimize"
else
  ok "OverlayWindow does not call page minimize"
fi
if rg -n -B8 'ZiYanPageEntryMinimizeOnce\(entry\)' "$APP" | rg -q 'startSelectedScriptFromPageEntry'; then
  ok "page helper is the only production caller"
else
  bad "expected startSelectedScriptFromPageEntry to call page minimize"
fi

say "== page entry names wired =="
for e in run learn drill auto; do
  if rg -q "startSelectedScriptFromPageEntry:@\"$e\"" "$APP"; then
    ok "page entry $e wired"
  else
    bad "missing page entry $e"
  fi
done

say "== volume / background must skip page minimize =="
if rg -n 'startSelectedScriptSkippingPageMinimize' "$APP" | rg -q 'app_run_trig'; then
  ok "background app_run_trig skips page minimize"
else
  # accept nearby call after the log
  if rg -n -A2 'app_run_trig\"' "$APP" | rg -q 'startSelectedScriptSkippingPageMinimize'; then
    ok "background app_run_trig skips page minimize"
  else
    bad "app_run_trig still goes through page minimize"
  fi
fi
if rg -n 'ZiYanPageEntryMinimizeOnce' "$OV"; then
  bad "OverlayWindow references page minimize"
else
  ok "volume menu has zero page-minimize references"
fi
if rg -n 'page_entry' "$OV" | rg -v '禁止走页面'; then
  bad "unexpected page_entry use in OverlayWindow"
else
  ok "volume menu comment-only page_entry mention"
fi

say "== Ensure already_ready still present =="
if rg -n 'via=already_ready' "$RUNNER" && rg -n 'already_ready' "$RUNNER" | rg -q 'wait_ms=0|禁止再叠'; then
  ok "Ensure already_ready fast path kept"
else
  if rg -n 'via=already_ready' "$RUNNER"; then
    ok "Ensure already_ready string kept"
  else
    bad "Ensure already_ready fast path missing"
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  echo "STATIC_TEST=FAIL"
  exit 1
fi
echo "STATIC_TEST=PASS"
exit 0
