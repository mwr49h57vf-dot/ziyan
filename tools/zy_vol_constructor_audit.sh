#!/bin/bash
# Static constructor audit for isolated or workspace Tweak.m.
# Does not prove runtime safety. Any unproven item => NOT_READY.
set -uo pipefail
FILE="${1:-}"
if [ -z "$FILE" ]; then
  echo "usage: $0 path/to/Tweak.m"
  exit 2
fi
if [ ! -f "$FILE" ]; then
  echo "CONSTRUCTOR_AUDIT=FAIL missing $FILE"
  exit 1
fi

python3 - "$FILE" <<'PY'
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
t = p.read_text()
m = re.search(r"__attribute__\(\(constructor\)\)\s+static void ZiYanVolInit\(void\)\s*\{", t)
if not m:
    print("CONSTRUCTOR_FOUND=NO")
    print("CONSTRUCTOR_AUDIT=FAIL")
    sys.exit(1)
# take from ctor to next top-level-ish end: next \n}\n at column 0 after start
start = m.start()
# find matching close of function: first line that is exactly "}"
rest = t[m.end()-1:]
depth = 0
end = None
for i, ch in enumerate(rest):
    if ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            end = i
            break
body = rest[: end + 1] if end is not None else rest[:4000]
print("CONSTRUCTOR_FOUND=YES")
print("CONSTRUCTOR_BYTES", len(body))
print("FILE", p)

def has(pat):
    return re.search(pat, body) is not None

checks = [
    ("no_uikit_sb_api", not has(r"UIApplication|SpringBoard|UIWindow|sharedApplication|hook"),
     "FAIL_HAS_UIKIT_OR_HOOK" if has(r"UIApplication|UIWindow|HookVolume|HookHome|ToastBridge|ScreenBridge") else "UNPROVEN"),
    ("no_sync_file_io", not has(r"WriteVarText|EnsureVarDirectory|stringWithContentsOfFile|removeItemAtPath|writeToFile"),
     "FAIL_HAS_SYNC_IO"),
    ("no_recursive_hook", not has(r"HookVolume|HookHome|method_exchange|MSHook"),
     "FAIL_INSTALLS_HOOKS"),
    ("no_unverified_private", not has(r"NSSelectorFromString|dlsym|class_getInstanceMethod"),
     "UNPROVEN_PRIVATE_OR_FAIL"),
    ("no_immortal_thread", not has(r"StartVolTrigPoller|dispatch_source|NSThread|pthread_create"),
     "FAIL_STARTS_POLLER"),
    ("no_global_input_mutate", not has(r"SetInterceptActive|gPresenting|HID"),
     "FAIL_MUTATES_INPUT"),
    ("safe_early_return", has(r"processName") and has(r"return;"),
     "FAIL_NO_EARLY_RETURN"),
]
fail = 0
for name, ok, why in checks:
    # last item: ok means proven pass
    if name == "safe_early_return":
        status = "PASS" if ok else "FAIL"
    else:
        status = "PASS" if ok else "FAIL"
    if status != "PASS":
        fail += 1
    print(f"{name}={status}" + ("" if status == "PASS" else f" reason={why}"))

print("NOTE=probe ZiYanHidSentTraceOnce is NOT in this constructor")
print("CONSTRUCTOR_CONSTRAINTS_PROVEN=NO" if fail else "CONSTRUCTOR_CONSTRAINTS_PROVEN=YES")
print("SAFE_DIAGNOSTIC_DYLIB=" + ("READY" if fail == 0 else "NOT_READY"))
sys.exit(0 if fail == 0 else 1)
PY
