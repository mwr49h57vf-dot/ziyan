#!/bin/sh
# One-shot startup segment probe. Env: H_TAG VAR SCRIPT APP
# Does not modify product code. Stops any leftover session first, then one menu_run.
set -u
H_TAG="${H_TAG:-unk}"
V="${VAR:-/usr/lib/ziyan/var}"
SCRIPT="${SCRIPT:-}"
APP="${APP:-}"
if [ -d /var/jb/usr/bin ]; then
  export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin
fi
now() { date +%s; }
front() { tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null; }
shmfront() { tr -d '\r\n' <"$V/.ziyan_shm_front_bid" 2>/dev/null; }
sess() { tr '\n' ' ' <"$V/.ziyan_session" 2>/dev/null; }
od1() { od -An -t u1 -j "$2" -N 1 "$1" 2>/dev/null | tr -d ' \n'; }
od4() { od -An -t u4 -j "$2" -N 4 "$1" 2>/dev/null | tr -d ' \n'; }
fc_n() { ps -axo args= | grep '[z]iyan_framecap serve' | grep -v grep | wc -l | tr -dc '0-9'; }
find_n() {
  s=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null)
  echo "$s" | sed -n 's/.*via_embed_find=\([0-9]*\).*/\1/p'
}

echo "META host=.$H_TAG pkg=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p' | head -1)"
echo "SCRIPT=$SCRIPT APP=$APP"
echo "FRONT0=$(front) SESSION0=$(sess)"
echo "HUMAN_INTERVENTION=0"

# Stop leftover session so this start is a real start
printf 'stop=1\n' >"$V/.ziyan_run_intent"
touch "$V/.ziyan_stop"
rm -f "$V/.ziyan_embed_go" "$V/.ziyan_menu_run_trig"
w=0
while [ "$w" -lt 20 ]; do
  echo "$(sess)" | grep -q 'state=idle' && break
  echo "$(sess)" | grep -q 'state=running' || break
  sleep 0.5
  w=$((w + 1))
done
sleep 1
echo "AFTER_STOP session=$(sess) front=$(front) fc=$(fc_n)"

# Snapshot / truncate logs for this run
cp -f "$V/.ziyan_minimize_log" "$V/.ziyan_minimize_log.bak_seg" 2>/dev/null || true
cp -f "$V/.ziyan_framecap_log" "$V/.ziyan_framecap_log.bak_seg" 2>/dev/null || true
: >"$V/.ziyan_minimize_log"
chmod 666 "$V/.ziyan_minimize_log" 2>/dev/null || true
# keep framecap_log but mark
echo "---- SEG_MARK $(date '+%F %T') ----" >>"$V/.ziyan_framecap_log"
# 新会话会 reset path_stats，T10 只认本次 via_embed_find>=1
FIND0=0
SEQ0=$(od4 "$V/.ziyan_frame_shm" 20)
AP0=$(od1 "$V/.ziyan_frame_shm" 50)
echo "BASE find0=$FIND0 seq0=$SEQ0 ap0=$AP0"

T0=$(now)
printf '%s\n' "$SCRIPT" >"$V/.ziyan_menu_run_trig"
chmod 666 "$V/.ziyan_menu_run_trig" 2>/dev/null || true
echo "T0=$T0 write_menu_run_trig"

T1=""; T2=""; T3=""; T3S=""; T4=""; T5=""; T6=""; T7=""; T8=""; T9=""; T10=""
i=0
while [ "$i" -lt 180 ]; do
  ts=$(now)
  ml=$(cat "$V/.ziyan_minimize_log" 2>/dev/null)
  fl=$(tail -c 8000 "$V/.ziyan_framecap_log" 2>/dev/null)
  fr=$(front)
  sh=$(shmfront)
  seq=$(od4 "$V/.ziyan_frame_shm" 20)
  ap=$(od1 "$V/.ziyan_frame_shm" 50)
  as=$(od1 "$V/.ziyan_frame_shm" 51)
  fn=$(find_n)
  fn=${fn:-0}

  if [ -z "$T1" ] && echo "$ml" | grep -q 'menu_run_enter'; then T1=$ts; echo "T1=$T1 menu_run_enter"; fi
  if [ -z "$T2" ] && echo "$ml" | grep -q 'ensure_framecap'; then T2=$ts; echo "T2=$T2 ensure_framecap $(echo "$ml" | grep ensure_framecap | tail -1)"; fi
  if [ -z "$T3" ] && echo "$ml" | grep -q 'menu_run_ok'; then T3=$ts; T3S=ok; echo "T3=$T3 menu_run_ok"; fi
  if [ -z "$T3" ] && echo "$ml" | grep -q 'menu_run_fail'; then T3=$ts; T3S=fail; echo "T3=$T3 menu_run_fail"; fi
  if [ -z "$T4" ] && echo "$ml" | grep -q 'minimize_begin'; then T4=$ts; echo "T4=$T4 minimize_begin"; fi
  if [ -z "$T5" ] && [ -n "$T3" ] && [ -n "$APP" ] && [ "$fr" = "$APP" ]; then T5=$ts; echo "T5=$T5 front=$fr"; fi
  if [ -z "$T6" ] && [ -n "$T3" ] && [ -n "$APP" ] && [ "$fr" = "$APP" ] && [ "$sh" = "$APP" ]; then T6=$ts; echo "T6=$T6 front=shm=$fr"; fi
  if [ -z "$T7" ] && [ -n "$T3" ] && [ -n "$APP" ] && [ "$fr" = "$APP" ] && [ "$as" = 0 ] && { [ "$ap" = 8 ] || [ "$ap" = 9 ]; } && [ -n "$seq" ] && [ "$seq" != "$SEQ0" ]; then
    T7=$ts
    echo "T7=$T7 healthy_frame ap=$ap as=$as seq=$seq"
  fi
  if [ -z "$T8" ] && { echo "$fl" | grep -q 'embed start' || [ -f "$V/.ziyan_lua_embedded" ]; }; then
    T8=$ts
    echo "T8=$T8 embed_start"
  fi
  if [ -z "$T9" ] && echo "$fl" | grep -qE 'prewarm_ready|prewarm_timeout'; then
    T9=$ts
    echo "T9=$T9 $(echo "$fl" | grep -E 'prewarm_ready|prewarm_timeout' | tail -1)"
  fi
  if [ -z "$T10" ] && [ -n "$T8" ] && [ "$fn" -ge 1 ]; then
    T10=$ts
    echo "T10=$T10 via_embed_find=$fn"
  fi

  # enough for a complete timeline
  if [ -n "$T3" ] && [ -n "$T10" ]; then
    break
  fi
  # fail fast if start failed
  if [ "$T3S" = fail ] && [ "$i" -gt 20 ]; then
    break
  fi
  sleep 0.5
  i=$((i + 1))
done
TEND=$(now)

echo "T0=$T0 T1=${T1:--} T2=${T2:--} T3=${T3:--} T3S=${T3S:--} T4=${T4:--} T5=${T5:--} T6=${T6:--} T7=${T7:--} T8=${T8:--} T9=${T9:--} T10=${T10:--} TEND=$TEND"
delta() {
  a="$1"; b="$2"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "-" ] && [ "$b" != "-" ]; then
    echo $((b - a))
  else
    echo NA
  fi
}
echo "SEG T0_T3=$(delta "$T0" "$T3") T3_T5=$(delta "$T3" "$T5") T5_T7=$(delta "$T5" "$T7") T7_T9=$(delta "$T7" "$T9") T9_T10=$(delta "$T9" "$T10") T0_T10=$(delta "$T0" "$T10") T0_TEND=$((TEND - T0))"
echo "END_FRONT=$(front) END_SHM=$(shmfront) END_SEQ=$(od4 "$V/.ziyan_frame_shm" 20) FC_N=$(fc_n)"
echo "ACTIVE=$(test -f "$V/.ziyan_active" && echo 1 || echo 0) KEEP=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)"
echo "SESSION=$(sess)"
echo "STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null)"
echo "ENSURE=$(tr '\n' ' ' <"$V/.ziyan_ensure_framecap_log" 2>/dev/null)"
echo "---- MINIMIZE_LOG ----"
cat "$V/.ziyan_minimize_log" 2>/dev/null
echo "---- FRAMECAP_FLAGS ----"
tail -c 12000 "$V/.ziyan_framecap_log" 2>/dev/null | grep -E 'uisurface_black|uicreate_inflight_stale|relay_forbidden_business|app_not_active_evidence|prewarm_|embed start|stale|timeout' | tail -40
echo "---- FRAMECAP_ERR_TAIL ----"
if [ -d /var/jb/usr/lib/ziyan/var ]; then
  tail -c 2000 /var/jb/usr/lib/ziyan/var/.ziyan_framecap_err 2>/dev/null
else
  tail -c 2000 /usr/lib/ziyan/var/.ziyan_framecap_err 2>/dev/null
fi
echo "HUMAN_INTERVENTION=0"
echo "SEG_DONE=1"
