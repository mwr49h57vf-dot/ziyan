#!/bin/sh
# Device-side open_app skip cases. Env: H_TAG VAR
set -u
H_TAG="${H_TAG:-unk}"
V="${VAR:-/usr/lib/ziyan/var}"
RUN_ID="openapp_${H_TAG}_$(date +%s)"
FINAL="/private/var/mobile/Media/ZiYan/verdicts/${RUN_ID}.txt"
mkdir -p /private/var/mobile/Media/ZiYan/verdicts
OS=$(sw_vers -productVersion 2>/dev/null || echo unknown)
PKG=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p' | head -1)
SB0=$(ps -ax -o pid,command | grep '/SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1)
BB0=$(ps -ax -o pid,command | grep '/usr/libexec/backboardd' | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1)
FC_N=$(ps -ax -o command= | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -d ' ')

front() { tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null; }
active() { if [ -f "$V/.ziyan_active" ]; then echo 1; else echo 0; fi; }
keep() { if [ -f "$V/.ziyan_keep_daemon" ]; then echo 1; else echo 0; fi; }

write_open() {
  printf '%s' "$1" >"$V/.ziyan_open_app"
  chmod 666 "$V/.ziyan_open_app" 2>/dev/null || true
}

wait_front() {
  want="$1"
  n=0
  while [ "$n" -lt 40 ]; do
    cur=$(front)
    [ "$cur" = "$want" ] && return 0
    sleep 0.5
    n=$((n + 1))
  done
  return 1
}

log_has() { grep -F "$1" "$V/.ziyan_open_app_log" >/dev/null 2>&1; }
clear_log() { : >"$V/.ziyan_open_app_log"; chmod 666 "$V/.ziyan_open_app_log" 2>/dev/null || true; }

read_bid() {
  p="$1"
  [ -f "$p" ] || return 0
  b=$(defaults read "${p%.plist}" CFBundleIdentifier 2>/dev/null || true)
  if [ -n "$b" ]; then echo "$b"; return 0; fi
  lines=$(tr '\0' '\n' <"$p" 2>/dev/null)
  b=$(printf '%s\n' "$lines" | sed -n '/CFBundleIdentifier/{n;s/.*<string>\([^<]*\)<\/string>.*/\1/p;s/^<string>\([^<]*\)<\/string>$/\1/p;}' | head -1)
  if [ -n "$b" ]; then echo "$b"; return 0; fi
  printf '%s\n' "$lines" | grep -E '^[A-Za-z][A-Za-z0-9.-]+\.[A-Za-z0-9.-]+$' | head -1
}

pick_user_bids() {
  u1=""; u2=""; n=0
  _list=/tmp/zy_open_app_plists.txt
  : >"$_list"
  find /var/containers/Bundle/Application /Applications /var/jb/Applications \
    -maxdepth 3 -name Info.plist 2>/dev/null | grep -v PlugIns | grep -v appex >>"$_list" || true
  while IFS= read -r p; do
    [ -f "$p" ] || continue
    b=$(read_bid "$p")
    [ -n "$b" ] || continue
    case "$b" in
      com.apple.*|com.ziyan.ziyan|com.saurik.*|org.coolstar.*) continue ;;
    esac
    n=$((n + 1))
    if [ "$n" -eq 1 ]; then u1="$b"; fi
    if [ "$n" -eq 2 ]; then u2="$b"; break; fi
  done <"$_list"
  echo "USER1=$u1"
  echo "USER2=$u2"
}

rm -f "$V/.ziyan_open_app" "$V/.ziyan_open_app.taking"
clear_log
USER1=""
USER2=""
eval "$(pick_user_bids | grep -E '^USER[12]=')"
SETTINGS="com.apple.Preferences"
ZIYAN="com.ziyan.ziyan"
MISSING="com.ziyan.no.such.app.invalid999"
FRONT_NOW=$(front)
if [ -z "${USER1:-}" ] && [ -n "$FRONT_NOW" ]; then
  case "$FRONT_NOW" in
    com.apple.*|com.ziyan.ziyan) ;;
    *) USER1="$FRONT_NOW" ;;
  esac
fi
if [ -z "${USER2:-}" ] || [ "${USER2:-}" = "${USER1:-}" ]; then
  USER2="$SETTINGS"
fi
echo "META os=$OS pkg=$PKG sb=$SB0 bb=$BB0 fc=$FC_N run=$RUN_ID"
echo "PICK user1=${USER1:-} user2=${USER2:-} settings=$SETTINGS"
echo "FRONT0=$(front) ACTIVE0=$(active) KEEP0=$(keep)"

pass=0
fail=0
record() {
  name="$1"
  ok="$2"
  extra="$3"
  if [ "$ok" = 1 ]; then
    echo "CASE $name PASS $extra"
    pass=$((pass + 1))
  else
    echo "CASE $name FAIL $extra"
    fail=$((fail + 1))
  fi
}

# 1 absent
f0=$(front)
rm -f "$V/.ziyan_open_app"
sleep 2
f1=$(front)
if [ ! -f "$V/.ziyan_open_app" ] && [ "$f1" = "$f0" ]; then
  record T1_ABSENT 1 "front=$f1"
else
  record T1_ABSENT 0 "front0=$f0 front=$f1"
fi

# 2 empty
clear_log
write_open ""
sleep 2
if log_has "event=open_app_skip_empty" && ! grep -F "event=open_app_ready" "$V/.ziyan_open_app_log" >/dev/null 2>&1; then
  record T2_EMPTY 1 "front=$(front)"
else
  record T2_EMPTY 0 "front=$(front) log=$(tail -c 300 "$V/.ziyan_open_app_log" | tr '\n' '|')"
fi

# 3 blank
clear_log
printf ' \t \n  \n' >"$V/.ziyan_open_app"
chmod 666 "$V/.ziyan_open_app" 2>/dev/null || true
sleep 2
if log_has "event=open_app_skip_empty" && ! grep -F "event=open_app_ready" "$V/.ziyan_open_app_log" >/dev/null 2>&1; then
  record T3_BLANK 1 "front=$(front)"
else
  record T3_BLANK 0 "front=$(front) log=$(tail -c 300 "$V/.ziyan_open_app_log" | tr '\n' '|')"
fi

# 4 first installed non-system app (fixture sample, not a product whitelist)
if [ -n "${USER1:-}" ]; then
  clear_log
  write_open "${USER1}
"
  if wait_front "$USER1"; then
    record T4_USER1 1 "bid=$USER1 front=$(front)"
  else
    record T4_USER1 0 "bid=$USER1 front=$(front)"
  fi
else
  record T4_USER1 0 "no_user_app_installed"
fi

# 5 another installed app
BID5="${USER2:-}"
if [ -z "$BID5" ] || [ "$BID5" = "${USER1:-}" ]; then
  BID5="$SETTINGS"
fi
clear_log
write_open "${BID5}
"
if wait_front "$BID5"; then
  record T5_USER2 1 "bid=$BID5 front=$(front)"
else
  record T5_USER2 0 "bid=$BID5 front=$(front)"
fi

# 6 settings
clear_log
write_open "${SETTINGS}
"
if wait_front "$SETTINGS"; then
  record T6_SETTINGS 1 "front=$(front)"
else
  record T6_SETTINGS 0 "front=$(front)"
fi

# 7 explicit ZiYan
clear_log
write_open "${ZIYAN}
"
if wait_front "$ZIYAN"; then
  record T7_ZIYAN 1 "front=$(front)"
else
  record T7_ZIYAN 0 "front=$(front)"
fi

# 8 missing: start from Settings so staying on ZiYan cannot be mistaken for fallback
clear_log
write_open "${SETTINGS}
"
wait_front "$SETTINGS" || true
sleep 1
f0=$(front)
clear_log
write_open "${MISSING}
"
sleep 3
f1=$(front)
if [ "$f1" = "$ZIYAN" ] && [ "$f0" != "$ZIYAN" ]; then
  record T8_MISSING 0 "fell_back_ziyan front=$f1"
elif [ "$f1" = "$ZIYAN" ] && [ "$f0" = "$ZIYAN" ]; then
  record T8_MISSING 0 "stayed_ziyan_ambiguous"
elif log_has "event=open_app_invalid" || log_has "event=launch_failed" || [ "$f1" != "$ZIYAN" ]; then
  record T8_MISSING 1 "front0=$f0 front=$f1"
else
  record T8_MISSING 0 "front0=$f0 front=$f1"
fi

# 9 one write: Vol and FrameRelay must not both ready
clear_log
write_open "${SETTINGS}
"
sleep 2.5
via_vol=$(grep -c "event=open_app_ready via=vol" "$V/.ziyan_open_app_log" 2>/dev/null || true)
via_rel=$(grep -c "event=open_app_ready via=relay" "$V/.ziyan_open_app_log" 2>/dev/null || true)
via_vol=${via_vol:-0}
via_rel=${via_rel:-0}
if [ "$via_vol" -gt 0 ] && [ "$via_rel" -gt 0 ]; then
  record T9_NODUP 0 "via_vol=$via_vol via_relay=$via_rel"
else
  record T9_NODUP 1 "via_vol=$via_vol via_relay=$via_rel"
fi

SB1=$(ps -ax -o pid,command | grep '/SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1)
BB1=$(ps -ax -o pid,command | grep '/usr/libexec/backboardd' | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1)
FC1=$(ps -ax -o command= | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -d ' ')
printf 'stop=1\n' >"$V/.ziyan_run_intent"
touch "$V/.ziyan_stop"
# 停止合同：无业务脚本时清 active/keep，再确认不再被 open_app 写回
rm -f "$V/.ziyan_active" "$V/.ziyan_keep_daemon"
sleep 1
ACT=$(active)
KP=$(keep)
if [ "$FC1" = 1 ]; then record T10_FCN 1 "fc=$FC1"; else record T10_FCN 0 "fc=$FC1"; fi
if [ "$SB1" = "$SB0" ] && [ "$BB1" = "$BB0" ]; then
  record T11_SB_PID 1 "sb=$SB1 bb=$BB1"
else
  record T11_SB_PID 0 "sb0=$SB0 sb1=$SB1 bb0=$BB0 bb1=$BB1"
fi
if [ "$ACT" = 0 ] && [ "$KP" = 0 ]; then
  record T12_STOP 1 "active=$ACT keep=$KP"
else
  record T12_STOP 0 "active=$ACT keep=$KP"
fi
if [ -n "$(front)" ]; then
  record T13_FRONT 1 "front=$(front)"
else
  record T13_FRONT 0 "front_empty"
fi
if [ ! -f "$V/.ziyan_vol_disarmed" ]; then
  record T14_VOLPLUS 1 "vol_plus_untouched vol_disarmed=0"
else
  record T14_VOLPLUS 0 "vol_disarmed_present"
fi

echo "SUMMARY pass=$pass fail=$fail sb=$SB1 bb=$BB1 fc=$FC1 front=$(front) active=$ACT keep=$KP"
if [ "$fail" -eq 0 ]; then VERDICT=PASS; else VERDICT=FAIL; fi
{
  echo "run_id=$RUN_ID"
  echo "host=$H_TAG"
  echo "os=$OS"
  echo "pkg=$PKG"
  echo "user1=${USER1:-}"
  echo "user2=${USER2:-}"
  echo "settings=$SETTINGS"
  echo "sb0=$SB0 sb1=$SB1 bb0=$BB0 bb1=$BB1 fc=$FC1"
  echo "pass=$pass fail=$fail"
  echo "VERDICT=$VERDICT"
} >"$FINAL"
echo "DEVICE_FINAL=$FINAL"
echo "VERDICT=$VERDICT"
echo "---- open_app_log ----"
cat "$V/.ziyan_open_app_log" 2>/dev/null
