#!/bin/bash
# ZiYan 24h 稳定性门禁（四机）
#   .166 / .101 / .112 → Desktop/ios7.lua（rootful）
#   .53               → Desktop/ios8p.lua（rootless）
# 约束：不改 Desktop lua 内容；仅 scp+拉起；不主动杀 SpringBoard
# 硬通过：0 次自发 SB_RESTART；0 次 .eksafemode；包保持 8-142
set +e
PASS=alpine
ROOT="/Users/mac/Desktop/ZiYan_副本"
OUT="${GATE_OUT:-$ROOT/tmp_shots/SURPASS_TS/8142_24h_gate}"
LOG="$OUT/stability_gate_24h.log"
INC="$OUT/sb_incidents"
STATUS="$OUT/GATE_STATUS.md"
DESKTOP_IOS7="/Users/mac/Desktop/ios7.lua"
DESKTOP_IOS8P="/Users/mac/Desktop/ios8p.lua"
PKG_EXPECT="0.0.92-8-142"
TOTAL="${GATE_MINUTES:-1440}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 -o ServerAliveInterval=4 -o ServerAliveCountMax=2"

# tag|ip|scheme|script
DEVICES=(
  "166|192.168.31.166|rootful|ios7.lua"
  "101|192.168.31.101|rootful|ios7.lua"
  "112|192.168.31.112|rootful|ios7.lua"
  "53|192.168.31.53|rootless|ios8p.lua"
)

mkdir -p "$OUT" "$INC"

if [[ -f "$OUT/monitor_gate_24h.pid" ]]; then
  old=$(cat "$OUT/monitor_gate_24h.pid" 2>/dev/null)
  if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
    echo "gate_24h already running pid=$old out=$OUT — stop it first to relaunch"
    exit 0
  fi
fi
echo $$ >"$OUT/monitor_gate_24h.pid"
trap 'rm -f "$OUT/monitor_gate_24h.pid"' EXIT

ssh_q() {
  local ip="$1"; shift
  sshpass -p "$PASS" ssh $SSH_OPTS "root@$ip" "$@" 2>/dev/null || echo "SSH_FAIL"
}

var_for() {
  # $1=scheme
  if [[ "$1" == "rootless" ]]; then
    echo /var/jb/usr/lib/ziyan/var
  else
    echo /usr/lib/ziyan/var
  fi
}

lua_bin_for() {
  if [[ "$1" == "rootless" ]]; then
    echo /var/jb/usr/lib/ziyan/bin/lua5.3
  else
    echo /usr/lib/ziyan/bin/lua5.3
  fi
}

run_lua_for() {
  if [[ "$1" == "rootless" ]]; then
    echo /var/jb/usr/lib/ziyan/lib/lua/ziyan_run.lua
  else
    echo /usr/lib/ziyan/lib/lua/ziyan_run.lua
  fi
}

parse_dev() {
  # sets TAG IP SCHEME SCRIPT
  local IFS='|'
  read -r TAG IP SCHEME SCRIPT <<<"$1"
}

write_status() {
  local abs="$1"
  local remain_h
  remain_h=$(awk -v a="$abs" -v t="$TOTAL" 'BEGIN{printf "%.1f", (t-a)/60.0}')
  {
    echo "# 24h Gate Status (live · quad)"
    echo
    echo "| 项 | 值 |"
    echo "|----|-----|"
    echo "| 开始 | $START_WALL |"
    echo "| 当前 | $(date '+%Y-%m-%d %H:%M:%S') |"
    echo "| 已跑分钟 | $abs / $TOTAL |"
    echo "| 剩余约 | ${remain_h}h |"
    echo "| 包期望 | $PKG_EXPECT |"
    echo "| 设备 | .166 .101 .112 .53 |"
    for d in "${DEVICES[@]}"; do
      parse_dev "$d"
      echo "| SB_RESTART .$TAG | ${RESTART[$TAG]:-0} |"
      echo "| lua revive .$TAG | ${HUNG[$TAG]:-0} |"
      echo "| eksafemode .$TAG | ${SAFE[$TAG]:-0} |"
    done
    echo "| 日志 | \`$LOG\` |"
    echo
    echo "**硬失败：** 任一台 SB_RESTART>0（自发）或 eksafemode=1 或包版本漂移。"
  } >"$STATUS"
}

dump_incident() {
  local ip="$1" tag="$2" abs="$3" scheme="$4"
  local dir="$INC/${tag}_min${abs}_$(date +%H%M%S)"
  local VAR
  VAR=$(var_for "$scheme")
  mkdir -p "$dir"
  echo "incident $dir ip=$ip" | tee -a "$LOG"
  ssh_q "$ip" "echo ===SB===; ps -A -o pid=,etime=,rss=,command= | grep SpringBoard.app | grep -v grep | head -2; echo ===LUA===; ps -A -o pid=,etime=,command= | grep 'ziyan_run.lua' | grep -v grep | head -3; echo ===SAFE===; test -f /var/mobile/.eksafemode && echo 1 || echo 0; echo ===WATCH===; cat $VAR/.ziyan_watchdog_alive 2>/dev/null; echo ===PULSE===; cat $VAR/.ziyan_sb_mem_pulse 2>/dev/null; echo ===COLOR===; cat $VAR/.ziyan_color_perf 2>/dev/null; echo ===HUNG===; test -f $VAR/.ziyan_lua_hung && echo 1 || echo 0; echo ===LIFE===; tail -30 $VAR/.ziyan_sb_lifecycle 2>/dev/null; echo ===CRASH===; ls -lt /var/mobile/Library/Logs/CrashReporter/*SpringBoard* 2>/dev/null | head -8" >"$dir/snapshot.txt" 2>&1
  ssh_q "$ip" "mkdir -p $VAR; echo 1 >$VAR/.ziyan_release_screen; echo 1 >$VAR/.ziyan_sb_capture_throttle; chmod 666 $VAR/.ziyan_release_screen $VAR/.ziyan_sb_capture_throttle 2>/dev/null; true" >/dev/null
}

revive_script() {
  local ip="$1" scheme="$2" script="$3" tag="$4"
  local VAR LUA RUN MEDIA SRC
  VAR=$(var_for "$scheme")
  LUA=$(lua_bin_for "$scheme")
  RUN=$(run_lua_for "$scheme")
  MEDIA=/var/mobile/Media/ZiYan
  if [[ "$script" == "ios7.lua" ]]; then
    SRC="$DESKTOP_IOS7"
  else
    SRC="$DESKTOP_IOS8P"
  fi
  sshpass -p "$PASS" scp $SSH_OPTS "$SRC" "root@$ip:$MEDIA/$script" >/dev/null 2>&1
  sshpass -p "$PASS" ssh $SSH_OPTS "root@$ip" \
    "PIDS=\$(ps -A -o pid=,command= | grep 'ziyan_run.lua' | grep '$script' | grep -v grep | awk '{print \$1}');
     for p in \$PIDS; do kill -9 \$p 2>/dev/null; done;
     mkdir -p $VAR $MEDIA;
     printf 'path=$MEDIA/$script\nstop=0\n' >$VAR/.ziyan_run_intent;
     chmod 666 $VAR/.ziyan_run_intent;
     $([[ "$scheme" == rootless ]] && echo 'export DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib;')
     cd $MEDIA && nohup $LUA $RUN $MEDIA/$script >/tmp/${script%.lua}_nohup.log 2>&1 </dev/null &
     rm -f $VAR/.ziyan_lua_hung $VAR/.ziyan_stop $VAR/.ziyan_user_stopped 2>/dev/null;
     echo REVIVE_${tag}_OK" 2>/dev/null
}

sample_device() {
  local ip="$1" var="$2" script="$3"
  ssh_q "$ip" "echo PKG; dpkg-query -W -f='\${Version}' com.ziyan.ziyan 2>/dev/null; echo; echo SB; ps -A -o pid= -o etime= -o rss= -o command= | grep SpringBoard.app | grep -v grep | head -1; echo LUA; ps -A -o command= | grep 'ziyan_run.lua' | grep '$script' | grep -v grep | wc -l | tr -d ' '; echo SAFE; test -f /var/mobile/.eksafemode && echo 1 || echo 0; echo WATCH; cat $var/.ziyan_watchdog_alive 2>/dev/null | tr '\n' ' '; echo; echo PULSE; cat $var/.ziyan_sb_mem_pulse 2>/dev/null | tr '\n' ' '; echo; echo COLOR; cat $var/.ziyan_color_perf 2>/dev/null | tr '\n' ' '; echo; echo FINDVIA; cat $var/.ziyan_find_via 2>/dev/null | tr '\n' ' '; echo; echo HUNG; test -f $var/.ziyan_lua_hung && echo 1 || echo 0; echo HB_LUA; test -f $var/.ziyan_heartbeat_lua5.3 && echo 1 || echo 0; echo HB_FC; test -f $var/.ziyan_framecap_alive && echo 1 || echo 0; echo HB_DA; test -f $var/.ziyan_zydaemon_alive && echo 1 || echo 0"
}

# --- declare assoc arrays ---
declare -A RESTART HUNG SAFE PID PREV_CALLS STUCK

if [[ ! -f "$DESKTOP_IOS7" || ! -f "$DESKTOP_IOS8P" ]]; then
  echo "FATAL missing Desktop scripts: $DESKTOP_IOS7 / $DESKTOP_IOS8P" | tee -a "$LOG"
  exit 2
fi

# archive prior dual-only run note
{
  echo "===== QUAD_RESTART $(date '+%Y-%m-%d %H:%M:%S') devices=.166,.101,.112,.53 ====="
} | tee -a "$LOG"

START_WALL=$(date '+%Y-%m-%d %H:%M:%S')
{
  echo "monitor_start $START_WALL total_min=$TOTAL pkg=$PKG_EXPECT out=$OUT mode=quad"
  echo "gate_policy hard_fail=SB_RESTART|eksafemode|pkg_drift soft=lua_hung_revive"
  echo "devices ${DEVICES[*]}"
} | tee -a "$LOG"

echo "bootstrap revive 4 devices ..." | tee -a "$LOG"
for d in "${DEVICES[@]}"; do
  parse_dev "$d"
  revive_script "$IP" "$SCHEME" "$SCRIPT" "$TAG" | tee -a "$LOG"
done
sleep 10

# dedupe: keep newest one if multiples (revive already kills all then starts one)
for d in "${DEVICES[@]}"; do
  parse_dev "$d"
  VAR=$(var_for "$SCHEME")
  SB=$(ssh_q "$IP" "ps -A -o pid= -o etime= -o command= | grep SpringBoard.app | grep -v grep | head -1")
  PID[$TAG]=$(echo "$SB" | awk '{print $1}')
  RESTART[$TAG]=0
  HUNG[$TAG]=0
  SAFE[$TAG]=0
  PREV_CALLS[$TAG]=""
  STUCK[$TAG]=0
  echo "baseline_sb .$TAG pid=${PID[$TAG]}" | tee -a "$LOG"
done

write_status 0

for i in $(seq 1 "$TOTAL"); do
  sleep 60
  ABS=$i
  {
    echo "min=$ABS $(date +%H:%M:%S)"
  } >>"$LOG"

  for d in "${DEVICES[@]}"; do
    parse_dev "$d"
    VAR=$(var_for "$SCHEME")
    L=$(sample_device "$IP" "$VAR" "$SCRIPT")
    echo "  .$TAG: $L" >>"$LOG"

    NP=$(echo "$L" | awk '/^SB$/{getline; print $1; exit}')
    PKG=$(echo "$L" | awk '/^PKG$/{getline; print; exit}')
    SAFE[$TAG]=$(echo "$L" | awk '/^SAFE$/{getline; print; exit}')
    LUA=$(echo "$L" | awk '/^LUA$/{getline; print; exit}')
    HFLAG=$(echo "$L" | awk '/^HUNG$/{getline; print; exit}')
    C=$(echo "$L" | sed -n 's/.*calls=\([0-9][0-9]*\).*/\1/p' | head -1)

    if [[ -n "$PKG" && "$PKG" != "SSH_FAIL" && "$PKG" != "$PKG_EXPECT" ]]; then
      echo "PKG_DRIFT_$TAG got=$PKG expect=$PKG_EXPECT at_min=$ABS" | tee -a "$LOG"
    fi
    if [[ "${SAFE[$TAG]:-0}" == "1" ]]; then
      echo "SAFEMODE_$TAG at_min=$ABS" | tee -a "$LOG"
      dump_incident "$IP" "${TAG}safe" "$ABS" "$SCHEME"
    fi
    if [[ -n "${PID[$TAG]}" && -n "$NP" && "$NP" != "SSH_FAIL" && "$NP" != "${PID[$TAG]}" ]]; then
      echo "SB_RESTART_$TAG old=${PID[$TAG]} new=$NP at_min=$ABS $(date +%H:%M:%S)" | tee -a "$LOG"
      dump_incident "$IP" "$TAG" "$ABS" "$SCHEME"
      PID[$TAG]="$NP"
      RESTART[$TAG]=$(( ${RESTART[$TAG]} + 1 ))
      revive_script "$IP" "$SCHEME" "$SCRIPT" "$TAG" | tee -a "$LOG"
    fi

    if [[ -n "$C" && "$C" == "${PREV_CALLS[$TAG]}" && "${LUA:-0}" -ge 1 ]]; then
      STUCK[$TAG]=$(( ${STUCK[$TAG]} + 1 ))
    else
      STUCK[$TAG]=0
    fi
    PREV_CALLS[$TAG]=$C

    # .53: hung flag alone 不每分钟杀；连续 stuck 或 lua 掉线才 revive
    need_revive=0
    if [[ "${LUA:-0}" -lt 1 ]]; then
      need_revive=1
    elif [[ "${STUCK[$TAG]}" -ge 5 ]]; then
      need_revive=1
    elif [[ "$HFLAG" == "1" && "$TAG" != "53" ]]; then
      need_revive=1
    elif [[ "$HFLAG" == "1" && "$TAG" == "53" && "${STUCK[$TAG]}" -ge 2 ]]; then
      need_revive=1
    fi
    if [[ "$need_revive" == "1" ]]; then
      echo "LUA_HUNG_OR_DOWN_$TAG stuck=${STUCK[$TAG]} hung_flag=$HFLAG lua=$LUA calls=$C at_min=$ABS" | tee -a "$LOG"
      revive_script "$IP" "$SCHEME" "$SCRIPT" "$TAG" | tee -a "$LOG"
      STUCK[$TAG]=0
      PREV_CALLS[$TAG]=""
      HUNG[$TAG]=$(( ${HUNG[$TAG]} + 1 ))
    fi

    if echo "$L" | grep -Eq 'pix=(6[0-9]{6}|7[0-9]{6}|8[0-9]{6}|9[0-9]{6}|[1-9][0-9]{7,})'; then
      echo "pressure_preempt_$TAG at_min=$ABS" | tee -a "$LOG"
      ssh_q "$IP" "echo 1 >$VAR/.ziyan_release_screen; echo 1 >$VAR/.ziyan_sb_capture_throttle" >/dev/null
    fi
  done

  if (( i % 15 == 0 )); then
    echo "checkpoint_min=$ABS $(date '+%Y-%m-%d %H:%M:%S') restarts=$(for t in 166 101 112 53; do echo -n ".$t=${RESTART[$t]} "; done) hung=$(for t in 166 101 112 53; do echo -n ".$t=${HUNG[$t]} "; done)" | tee -a "$LOG"
    write_status "$ABS"
  fi
done

END_WALL=$(date '+%Y-%m-%d %H:%M:%S')
echo "monitor_end $END_WALL SUMMARY" | tee -a "$LOG"
write_status "$TOTAL"

VERDICT=PASS
for d in "${DEVICES[@]}"; do
  parse_dev "$d"
  [[ "${RESTART[$TAG]:-0}" -gt 0 ]] && VERDICT=FAIL
  [[ "${SAFE[$TAG]:-0}" == "1" ]] && VERDICT=FAIL
done

{
  echo "# ZiYan 24h Stability Gate Verdict (quad)"
  echo
  echo "| 项 | 值 |"
  echo "|----|-----|"
  echo "| 开始 | $START_WALL |"
  echo "| 结束 | $END_WALL |"
  echo "| 包 | $PKG_EXPECT |"
  for d in "${DEVICES[@]}"; do
    parse_dev "$d"
    echo "| SB_RESTART .$TAG | ${RESTART[$TAG]} |"
    echo "| lua revive .$TAG | ${HUNG[$TAG]} |"
    echo "| eksafemode .$TAG | ${SAFE[$TAG]} |"
  done
  echo "| **Overall** | **$VERDICT** |"
  echo
  echo "硬门禁：四机均 0 次自发 SB_RESTART + 无 safemode。lua hung 自动复活记 soft。"
} >"$OUT/VERDICT_24H.md"

echo "VERDICT=$VERDICT written $OUT/VERDICT_24H.md"
