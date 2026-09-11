#!/usr/bin/env bash
# Z1-MEM 短窗（C98 现包）。禁 pretest_clean、禁 Desktop ios7/ios8p。.53 已恢复进验收集。
# 用法：ZY_E4_MIN=5 bash tools/zy_z1_mem_c98_gate.sh [53 101 112 166]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
MIN="${ZY_E4_MIN:-5}"
SEC=$((MIN * 60))
RMAX100="${ZY_E4_RMAX100_RF:-120}"
if [ "$#" -eq 0 ]; then HOSTS=(101 112 166 53 61); else HOSTS=("$@"); fi
for h in "${HOSTS[@]}"; do
  case "$h" in 53|61|101|112|166) ;; *) echo "refuse host=$h (ZiYan accept: 53 61 101 112 166; TS observe only)"; exit 2 ;; esac
done
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/Z1_MEM_C98_${STAMP}"
mkdir -p "$OUT"
SSH_KEY_OPTS=(-o BatchMode=yes -o PasswordAuthentication=no -o StrictHostKeyChecking=no
              -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
              -o ServerAliveInterval=20 -o ServerAliveCountMax=6)
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o ServerAliveInterval=20
          -o ServerAliveCountMax=6)
# 探测必须 ssh -n，避免吃掉调用方 heredoc；真正执行禁止 -n。
# 密钥优先对 mobile 同样生效：.61 的密码通道是间歇性的（实测连续 3 次里约 1 次
# Permission denied），密码路径还会被设备 sshd 限流（2026-09-11 五机 E48 实测
# 跑到一半 rc=255）。密钥不可用才回退 alpine。
ssh_mem() {
  local user="$1" ip="$2"; shift 2
  if ssh -n "${SSH_KEY_OPTS[@]}" "$user@$ip" "true" >/dev/null 2>&1; then
    ssh "${SSH_KEY_OPTS[@]}" "$user@$ip" "$@"
  else
    sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$user@$ip" "$@"
  fi
}
scp_mem() {
  local user="$1" ip="$2" src="$3" dst="$4"
  if ssh -n "${SSH_KEY_OPTS[@]}" "$user@$ip" "true" >/dev/null 2>&1; then
    scp "${SSH_KEY_OPTS[@]}" "$user@$ip:$src" "$dst"
  else
    sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "$user@$ip:$src" "$dst"
  fi
}
echo "OUT=$OUT MIN=$MIN hosts=${HOSTS[*]} no_desktop_lua no_pretest" | tee "$OUT/meta.txt"

app_for() {
  local h="$1" ov
  eval "ov=\${ZY_MEM_APP_${h}:-}"
  if [ -n "$ov" ]; then
    printf '%s\n' "$ov"
  else
    printf '%s\n' "${ZY_MEM_APP:-com.xztl.ios}"
  fi
}

run_one() {
  local H="$1" IP="192.168.31.$1" APP USER=root
  [ "$H" = 61 ] && USER=mobile
  APP=$(app_for "$H")
  ssh_mem "$USER" "$IP" \
    "H=$H SEC=$SEC MIN=$MIN RMAX100=$RMAX100 APP=$APP bash -s" >"$OUT/gate_${H}.txt" 2>&1 <<'EOS'
set +e
if [ -d /var/jb/usr/lib/ziyan/var ]; then
  V=/var/jb/usr/lib/ziyan/var
else
  V=/usr/lib/ziyan/var
fi
M=/private/var/mobile/Media/ZiYan
APP="${APP:-com.xztl.ios}"
echo "META host=.$H APP=$APP VER=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p') start=$(date +%s)"
echo 1 >"$V/.ziyan_no_auto_keep"
chmod 666 "$V/.ziyan_no_auto_keep" 2>/dev/null
rm -f "$V/.ziyan_force_recap" "$V/.ziyan_toast_bump" "$V/.ziyan_relay_req" \
  "$V/.ziyan_path_stats" "$V/.ziyan_keep_daemon" "$V/.ziyan_session_keep" \
  "$V/.ziyan_active" "$V/.ziyan_embed_go" "$M/_z1_mem_c98.lua" "$M/_z1_mem_c98_out.txt"
f=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
if [ "$f" != "$APP" ]; then
  printf '%s\n' "$APP" >"$V/.ziyan_open_app"
  chmod 666 "$V/.ziyan_open_app" 2>/dev/null
  i=0
  while [ "$i" -lt 20 ]; do
    f=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
    [ "$f" = "$APP" ] && break
    sleep 0.5
    i=$((i+1))
  done
  rm -f "$V/.ziyan_open_app"
fi
echo "FRONT0=$(tr -d '\r\n' <"$V/.ziyan_front_bid")"

sb_pid() {
  ps -axo pid=,args= 2>/dev/null | while read -r pid args; do
    case "$args" in
      */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo "$pid"; break ;;
    esac
  done
}
fc_pid() {
  ps -axo pid=,args= 2>/dev/null | while read -r pid args; do
    case "$args" in
      *ziyan_framecap\ serve*) echo "$pid"; break ;;
    esac
  done
}
FC_PID=$(fc_pid)
fc_rss_kb() {
  local r=""
  [ -n "$FC_PID" ] && r=$(ps -p "$FC_PID" -o rss= 2>/dev/null | tr -d ' ')
  if [ -z "$r" ]; then
    FC_PID=$(fc_pid)
    [ -n "$FC_PID" ] && r=$(ps -p "$FC_PID" -o rss= 2>/dev/null | tr -d ' ')
  fi
  echo "${r:-0}"
}
echo "FC_PID0=$FC_PID SB0=$(sb_pid)"
FC0=$(ps -axo args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9')
[ -n "$FC0" ] || FC0=0
echo "FC_N0=$FC0"
if [ "$FC0" -eq 0 ]; then
  launchctl kickstart system/com.ziyan.framecap 2>/dev/null || true
  sleep 2
  FC_PID=$(fc_pid)
fi

RUN_SEC=$((SEC + 120))
cat >"$M/_z1_mem_c98.lua" <<LUA
function main()
  init(1)
  keepScreen(true)
  local out = "/private/var/mobile/Media/ZiYan/_z1_mem_c98_out.txt"
  local function w(s)
    local f = io.open(out, "a")
    if f then f:write(tostring(s) .. "\\n"); f:close() end
  end
  w("started")
  local t0 = os.time()
  local n, hit = 0, 0
  while (os.time() - t0) < $RUN_SEC do
    local x, y = -1, -1
    if type(findMultiColorInRegionFuzzy) == "function" then
      x, y = findMultiColorInRegionFuzzy(0xc19b67, "1|2|0xb68b50,1|4|0xd3b281,0|5|0xd8b788", 90, 700, 440, 720, 470)
    end
    n = n + 1
    if tonumber(x) and x >= 0 then hit = hit + 1 end
    if n == 1 or n % 10 == 0 then
      w(string.format("pulse n=%d hit=%d", n, hit))
    end
    mSleep(400)
  end
  keepScreen(false)
  w(string.format("find_n=%d hit=%d", n, hit))
  w("done")
end
LUA
chmod 666 "$M/_z1_mem_c98.lua"

printf 'ts=1\n' >"$V/.ziyan_kill_scripts"; sleep 1
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_user_stopped" "$V/.ziyan_stop" \
  "$V/.ziyan_embed_off" "$V/.ziyan_active"
printf 'path=%s/_z1_mem_c98.lua\nstop=0\n' "$M" >"$V/.ziyan_run_intent"
printf '%s/_z1_mem_c98.lua\n' "$M" >"$V/.ziyan_embed_script"
echo 1 >"$V/.ziyan_embed_on"
echo "nonce=z1mem_${H}_$$" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" "$V/.ziyan_embed_on" "$V/.ziyan_embed_go"

sleep 60
echo 1 >"$V/.ziyan_force_recap"
sleep 3
rm -f "$V/.ziyan_force_recap"
sleep 2

SB0=$(sb_pid); SB0=${SB0:-0}
echo "SB0=$SB0 FC_PID=$FC_PID"
BASE_SAMPLES=""
i=1
while [ "$i" -le 15 ]; do
  BASE_SAMPLES="$BASE_SAMPLES $(fc_rss_kb)"
  sleep 2
  i=$((i+1))
done
RSS_BASE=$(echo "$BASE_SAMPLES" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | sed -n '8p')
RSS_BASE=${RSS_BASE:-0}
echo "WARM_BASE_RSS_KB=$RSS_BASE samples=$BASE_SAMPLES"

FORCE=0; TOAST=0; SB_CHG=0; KEEP_PEAK=0; FC_N_MAX=0; RELAY=0
: >"$V/.ziyan_e4_resource.tsv"
echo -e "t\tfc_n\tfc_rss\tsb_rss\tkeep" >>"$V/.ziyan_e4_resource.tsv"
end=$(( $(date +%s) + SEC ))
TAIL_BUF=""
FC_RSS_MAX=$RSS_BASE
while [ "$(date +%s)" -lt "$end" ]; do
  [ -f "$V/.ziyan_force_recap" ] && { FORCE=$((FORCE+1)); rm -f "$V/.ziyan_force_recap"; }
  [ -f "$V/.ziyan_toast_bump" ] && { TOAST=$((TOAST+1)); rm -f "$V/.ziyan_toast_bump"; }
  [ -f "$V/.ziyan_relay_req" ] && { RELAY=$((RELAY+1)); rm -f "$V/.ziyan_relay_req"; }
  [ -f "$V/.ziyan_keep_daemon" ] && KEEP_PEAK=1
  SB=$(sb_pid); SB=${SB:-0}
  if [ "$SB0" != "0" ] && [ "$SB" != "0" ] && [ "$SB" != "$SB0" ]; then
    SB_CHG=$((SB_CHG+1))
    echo "SB_RING from=$SB0 to=$SB"
    SB0=$SB
  fi
  FC_N=$(ps -axo args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9')
  [ -n "$FC_N" ] || FC_N=0
  [ "$FC_N" -gt "$FC_N_MAX" ] 2>/dev/null && FC_N_MAX=$FC_N
  FC_R=$(fc_rss_kb)
  [ "$FC_R" -gt "$FC_RSS_MAX" ] 2>/dev/null && FC_RSS_MAX=$FC_R
  SB_RSS=$(ps -p "$(sb_pid)" -o rss= 2>/dev/null | tr -d ' ')
  KEEP_NOW=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
  echo -e "$(date +%s)\t$FC_N\t$FC_R\t${SB_RSS:-0}\t$KEEP_NOW" >>"$V/.ziyan_e4_resource.tsv"
  TAIL_BUF="$TAIL_BUF $FC_R"
  TAIL_BUF=$(echo "$TAIL_BUF" | tr ' ' '\n' | grep -E '^[0-9]+$' | tail -15 | tr '\n' ' ')
  sleep 2
done

RSS_END=$(echo "$TAIL_BUF" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | sed -n '8p')
RSS_END=${RSS_END:-0}
FC_DELTA=$((RSS_END - RSS_BASE))
FC_PER100=$((FC_DELTA * 100 / SEC))

printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
sleep 2
rm -f "$V/.ziyan_active" "$V/.ziyan_keep_daemon" "$V/.ziyan_session_keep" \
  "$V/.ziyan_run_intent" "$V/.ziyan_embed_go" "$V/.ziyan_embed_script"
sleep 1
KEEP_AFTER=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
ACTIVE=$(test -f "$V/.ziyan_active" && echo 1 || echo 0)
STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null)
CR=$(echo "$STATS" | sed -n 's/.*via_color_req_find=\([0-9][0-9]*\).*/\1/p')
EM=$(echo "$STATS" | sed -n 's/.*via_embed_find=\([0-9][0-9]*\).*/\1/p')
[ -z "$CR" ] && CR=-1
[ -z "$EM" ] && EM=-1
WS=$(tr '\n' ' ' <"$V/.ziyan_workset_bytes" 2>/dev/null)
WS_N=$(echo "$WS" | sed 's/[^0-9].*//' | tr -dc '0-9')
[ -n "$WS_N" ] || WS_N=0
INVALID=0
if [ -s "$M/_z1_mem_c98_out.txt" ]; then
  LUA_OUT=$(tr '\n' ' ' <"$M/_z1_mem_c98_out.txt")
  echo "LUA_OUT=$LUA_OUT"
else
  echo "CLASS=INVALID_RUN reason=lua_out_missing"
  echo "LUA_OUT="
  INVALID=1
fi
FRONT1=$(tr -d '\r\n' <"$V/.ziyan_front_bid")
echo "FRONT1=$FRONT1"
echo "STATS=$STATS"
echo "SB_CHG=$SB_CHG FORCE_HITS=$FORCE TOAST_BUMP=$TOAST KEEP_PEAK=$KEEP_PEAK RELAY_HITS=$RELAY"
echo "FC_N_MAX=$FC_N_MAX RSS_BASE=$RSS_BASE RSS_END=$RSS_END FC_RSS_MAX=$FC_RSS_MAX"
echo "FC_SLOPE_KB=$FC_DELTA FC_SLOPE_PER100_KB=$FC_PER100 window_sec=$SEC budget_per100=$RMAX100"
echo "WORKSET=$WS KEEP_AFTER_STOP=$KEEP_AFTER ACTIVE=$ACTIVE"
echo "via_embed_find=$EM via_color_req_find=$CR"
echo "FC_PID1=$(fc_pid) SB1=$(sb_pid)"

OK=1
[ "$SB_CHG" = 0 ] || { echo "FAIL sb_ring=$SB_CHG"; OK=0; }
[ "$KEEP_AFTER" = 0 ] || { echo "FAIL keep_after_stop"; OK=0; }
[ "$ACTIVE" = 0 ] || { echo "FAIL sticky_active"; OK=0; }
[ "${FC_N_MAX:-0}" -le 1 ] 2>/dev/null || { echo "FAIL fc_n_max=$FC_N_MAX"; OK=0; }
[ "$WS_N" -le 6291456 ] 2>/dev/null || { echo "FAIL workset_over_6mb=$WS_N"; OK=0; }
[ "$TOAST" = 0 ] || { echo "FAIL toast_bump=$TOAST"; OK=0; }
FMAX=$((MIN * 2 + 5))
[ "$FORCE" -le "$FMAX" ] 2>/dev/null || { echo "FAIL force_storm=$FORCE max=$FMAX"; OK=0; }
[ "$EM" -gt 10 ] 2>/dev/null || { echo "FAIL embed_find_low=$EM"; OK=0; }
# 本窗只跑 embed；color_req 应为 0。短窗斜率只记，不作唯一 FAIL。
if [ "$CR" != 0 ] && [ "$CR" != -1 ]; then
  echo "FAIL color_req=$CR"
  OK=0
fi
if [ "$FC_PER100" -gt "$RMAX100" ] 2>/dev/null; then
  echo "NOTE fc_rss_slope_per100=$FC_PER100 over short-window budget $RMAX100 (not sole FAIL)"
fi
[ "$FRONT1" = "$APP" ] || { echo "FAIL front_left_game=$FRONT1"; OK=0; }
rm -f "$M/_z1_mem_c98.lua" "$V/.ziyan_no_auto_keep"
if [ "$INVALID" = 1 ]; then
  VDICT=INVALID_RUN
elif [ "$OK" = 1 ]; then
  VDICT=PASS
else
  VDICT=FAIL
fi
echo "VERDICT=$VDICT"
echo "META end=$(date +%s)"
RID="mem_${H}_$(date +%s)"
mkdir -p "$M/verdicts"
{
  echo "run_id=$RID"
  echo "host=.$H"
  echo "pkg=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')"
  echo "min=$MIN"
  echo "FC_N_MAX=${FC_N_MAX:-}"
  echo "SB_CHG=${SB_CHG:-}"
  echo "KEEP_AFTER_STOP=${KEEP_AFTER:-}"
  echo "VERDICT=$VDICT"
  echo "final=1"
} >"$M/verdicts/${RID}.txt"
echo "DEVICE_FINAL=$RID"
exit 0
EOS
}

ts_snap() {
  local host="$1" dest="$2"
  ssh_mem root "192.168.31.$host" \
    'echo HOST='$host'; date; ps -axo pid=,rss=,%cpu=,etime=,args= | while read -r pid rss cpu etime args; do case "$args" in *TSDaemon\ -server*) echo ROLE=TSDaemon PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo ROLE=SpringBoard PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; esac; done' \
    >"$dest" 2>&1 || echo "SSH_FAIL" >>"$dest"
}

ts_snap 171 "$OUT/ts171_start.txt" &
ts_snap 149 "$OUT/ts149_start.txt" &
wait || true

for H in "${HOSTS[@]}"; do
  run_one "$H" &
  echo $! >"$OUT/pid_${H}.txt"
done
echo "waiting ${MIN}min workers…"
wait || true

ts_snap 171 "$OUT/ts171_end.txt" &
ts_snap 149 "$OUT/ts149_end.txt" &
wait || true

PASS_N=0
FAIL_N=0
{
  if [ "$MIN" -eq 10 ]; then
    echo "# Z2-10M-PRELIM (not final Z2-30M)"
  elif [ "$MIN" -ge 30 ]; then
    echo "# Z1-MEM C98 ${MIN}min window"
  else
    echo "# Z1-MEM C98 short window"
  fi
  echo "stamp=$STAMP min=$MIN hosts=${HOSTS[*]}"
  echo "no_desktop_lua no_pretest"
  echo "slope_budget_per100=$RMAX100 (short window informational if over)"
  echo
  echo "| host | verdict | FC_N | SB_CHG | keep_after | embed_find | color_req | RSS_BASE/END | PER100 | workset |"
  echo "|---|---|---|---|---|---|---|---|---|---|"
  for H in "${HOSTS[@]}"; do
    f="$OUT/gate_${H}.txt"
    v=$(sed -n 's/^VERDICT=//p' "$f" | tail -1)
    df=$(sed -n 's/^DEVICE_FINAL=//p' "$f" | tail -1)
    if [ -z "$v" ] || [ -z "$df" ]; then
      v=INVALID_RUN
      FAIL_N=$((FAIL_N+1))
    elif [ "$v" = INVALID_RUN ]; then
      FAIL_N=$((FAIL_N+1))
    elif [ "$v" = PASS ]; then
      PASS_N=$((PASS_N+1))
    else
      FAIL_N=$((FAIL_N+1))
    fi
    echo "| .$H | ${v:-MISSING} | $(sed -n 's/^FC_N_MAX=//p' "$f" | head -1) | $(sed -n 's/^SB_CHG=//p' "$f" | awk '{print $1}' | head -1) | $(sed -n 's/^KEEP_AFTER_STOP=//p' "$f" | awk '{print $1}' | head -1) | $(sed -n 's/^via_embed_find=//p' "$f" | awk '{print $1}' | head -1) | $(sed -n 's/^via_color_req_find=//p' "$f" | awk '{print $1}' | head -1) | $(sed -n 's/^RSS_BASE=//p' "$f" | awk '{print $1}' | head -1)/$(sed -n 's/.*RSS_END=//p' "$f" | awk '{print $1}' | head -1) | $(sed -n 's/.*FC_SLOPE_PER100_KB=//p' "$f" | awk '{print $1}' | head -1) | $(sed -n 's/^WORKSET=//p' "$f" | awk '{print $1}' | head -1) |"
  done
  echo
  if [ "$FAIL_N" -eq 0 ] && [ "$PASS_N" -eq "${#HOSTS[@]}" ]; then
    echo "VERDICT=PASS"
  else
    echo "VERDICT=FAIL"
  fi
  echo
  if [ "$MIN" -ge 10 ]; then
    echo
    if [ "$MIN" -eq 10 ]; then
      echo "## Z2-10M-PRELIM OLS (not final Z2-30M)"
    else
      echo "## 30min OLS (KB/s * 100 = KB/100s)"
    fi
    for H in "${HOSTS[@]}"; do
      if [ "$H" = 53 ]; then
        _v=/var/jb/usr/lib/ziyan/var
      else
        _v=/usr/lib/ziyan/var
      fi
      _u=root
      [ "$H" = 61 ] && _u=mobile
      scp_mem "$_u" "192.168.31.$H" "$_v/.ziyan_e4_resource.tsv" \
        "$OUT/rss_${H}.tsv" 2>/dev/null || true
      if [ -s "$OUT/rss_${H}.tsv" ]; then
        python3 "$ROOT/tools/zy_rss_slope_analyze.py" "$OUT/rss_${H}.tsv" || echo "OLS .$H analyze_fail"
      else
        echo "OLS .$H tsv_missing"
      fi
    done
    echo
    if [ "$MIN" -eq 10 ]; then
      echo "10min OLS is Z2-10M-PRELIM only. Do not write final Z2 PASS. Keep existing 30min reports."
    else
      echo "30min OLS is the long-window slope. Short PER100 is still informational. No surpass claim."
    fi
  else
    echo "5min slope is not 30min OLS. Not TouchSprite internal RSS. No surpass claim."
  fi
} | tee "$OUT/REPORT.md" "$OUT/VERDICT.md"
echo "OUT=$OUT"
grep -q 'VERDICT=PASS' "$OUT/VERDICT.md"
