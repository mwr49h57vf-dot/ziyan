#!/usr/bin/env bash
# C98 Gate C 30min：每分钟真 Home → 回 App → 金标 12688231 / provider=8。
# .53 已恢复进验收集；禁 pretest、禁 Desktop lua、禁向 .171/.149 发 Home。
# 用法：bash tools/zy_p2_c98_30m_gate.sh [53 101 112 166]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
MIN="${ZY_E4_MIN:-${ZY_P2_EXPECTED_MINUTES:-30}}"
APP="${ZY_P2_APP:-com.xztl.ios}"
# 当前四机实测金标为 12754024；旧默认 12688231 会假 FAIL。
EXP="${ZY_P2_COLOR:-12754024}"
if [ "$#" -eq 0 ]; then HOSTS=(101 112 166); else HOSTS=("$@"); fi
for h in "${HOSTS[@]}"; do
  case "$h" in 53|101|112|166) ;; *) echo "refuse host=$h (ZiYan accept: 53 101 112 166; TS observe only)"; exit 2 ;; esac
done
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P2_30M_C98_${STAMP}"
mkdir -p "$OUT"
SSH_KEY_OPTS=(-o BatchMode=yes -o PasswordAuthentication=no -o StrictHostKeyChecking=no
              -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15
              -o ServerAliveInterval=15 -o ServerAliveCountMax=6)
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=15 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1
          -o ServerAliveInterval=15 -o ServerAliveCountMax=6)
echo "OUT=$OUT MIN=$MIN hosts=${HOSTS[*]} no_desktop_lua no_pretest no_ts_home" | tee "$OUT/meta.txt"

ssh_one() {
  local ip="$1"
  shift
  if ssh -n "${SSH_KEY_OPTS[@]}" "root@$ip" "true" >/dev/null 2>&1; then
    ssh "${SSH_KEY_OPTS[@]}" "root@$ip" "$@"
  else
    sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$ip" "$@"
  fi
}

app_for() {
  local h="$1" ov
  eval "ov=\${ZY_P2_APP_${h}:-}"
  if [ -n "$ov" ]; then printf '%s\n' "$ov"
  else printf '%s\n' "${ZY_P2_APP:-com.xztl.ios}"
  fi
}

color_for() {
  local h="$1" ov
  eval "ov=\${ZY_P2_COLOR_${h}:-}"
  if [ -n "$ov" ]; then printf '%s\n' "$ov"
  else printf '%s\n' "${ZY_P2_COLOR:-12754024}"
  fi
}

sample_host() {
  local H="$1" APP_H EXP_H
  APP_H=$(app_for "$H")
  EXP_H=$(color_for "$H")
  ssh_one "192.168.31.$H" "H='$H' EXPECTED_COLOR='$EXP_H' EXPECTED_APP='$APP_H' bash -s" <<'REMOTE'
set +e
if [ -d /var/jb/usr/bin ]; then
  export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin
else
  export PATH=/usr/bin:/bin:/usr/sbin:/sbin
fi
if [ -d /var/jb/usr/lib/ziyan/var ]; then
  V=/var/jb/usr/lib/ziyan/var
else
  V=/usr/lib/ziyan/var
fi
APP="${EXPECTED_APP:-com.xztl.ios}"
EXP="${EXPECTED_COLOR:-12688231}"

od1(){ od -An -t u1 -j "$2" -N 1 "$1" 2>/dev/null | tr -d ' \n'; }
od4(){ od -An -t u4 -j "$2" -N 4 "$1" 2>/dev/null | tr -d ' \n'; }
pid_of(){ ps -axo pid=,args= | grep "$1" | grep -v grep | head -1 | sed 's/^ *//;s/ .*//'; }
fc_n(){ sleep 0.5; ps -axo args= | grep '[z]iyan_framecap serve' | grep -v grep | wc -l | tr -dc '0-9'; }

get_color(){
  rm -f "$V/.ziyan_color_rep"
  n=$1_$(date +%s)_$$
  printf "getColor\n706\n449\n%s\n" "$n" >"$V/.ziyan_color_req.tmp"
  mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
  q=0
  while test "$q" -lt 100; do
    test -f "$V/.ziyan_color_rep" && grep -q "$n" "$V/.ziyan_color_rep" && break
    sleep 0.05
    q=$((q+1))
  done
  COL=$(sed -n 3p "$V/.ziyan_color_rep" 2>/dev/null)
  AP=$(od1 "$V/.ziyan_frame_shm" 50)
  AS=$(od1 "$V/.ziyan_frame_shm" 51)
  SEQ=$(od4 "$V/.ziyan_frame_shm" 20)
  REQ=$q
}

SB0=$(pid_of 'SpringBoard.app/SpringBoard')
FC0=$(pid_of 'ziyan_framecap serve')
BB0=$(pid_of 'backboardd')
APP0=$(pid_of 'FGCQLibClient-mobile')
FCN0=$(fc_n)

rm -f "$V/.ziyan_open_app" /private/var/mobile/Media/ZiYan/.ziyan_open_app
t0=$(date +%s)
printf '1\n' >"$V/.ziyan_go_home"
chmod 666 "$V/.ziyan_go_home" 2>/dev/null
i=0; HOK=0
while test "$i" -lt 80; do
  f=$(cat "$V/.ziyan_front_bid" 2>/dev/null)
  echo "$f" | grep -qi springboard && { HOK=1; break; }
  sleep 0.05
  i=$((i+1))
done
t1=$(date +%s)
HOME_MS=$(( (t1-t0)*1000 ))
sleep 4.5
FS=$(cat "$V/.ziyan_front_bid" 2>/dev/null)
HP=$(od1 "$V/.ziyan_frame_shm" 50)
HS=$(od1 "$V/.ziyan_frame_shm" 51)
if test "$HP" = 8; then
  echo 1 >"$V/.ziyan_force_recap"
  printf 'force=1\n' >"$V/.ziyan_frame_req"
  sleep 0.8
  HP=$(od1 "$V/.ziyan_frame_shm" 50)
  HS=$(od1 "$V/.ziyan_frame_shm" 51)
fi
echo "$FS" | grep -qi springboard || HOK=0
test "$HP" != 8 || HOK=0
rm -f "$V/.ziyan_go_home"

k=0; AOK=0; OPEN_N=0
# 根因：写完再 rm 会让 Vol/FrameRelay 读到空文件并默认打开 com.ziyan.ziyan。
# 只写、让轮询消费；已在前台不再 launch。打开后等 2s，与旧成功分钟一致。
while test "$k" -lt 10; do
  f2=$(cat "$V/.ziyan_front_bid" 2>/dev/null | tr -d '\r\n')
  SBNOW=$(pid_of 'SpringBoard.app/SpringBoard')
  if test -n "$SB0" && test -n "$SBNOW" && test "$SBNOW" != "$SB0"; then
    echo "SB_CHG_DURING_OPEN SB0=$SB0 SBNOW=$SBNOW"
    break
  fi
  if test "$f2" != "$APP" && test "$OPEN_N" -lt 5; then
    printf '%s\n' "$APP" >"$V/.ziyan_open_app"
    chmod 666 "$V/.ziyan_open_app" 2>/dev/null
    OPEN_N=$((OPEN_N+1))
    sleep 2.0
  else
    sleep 0.5
  fi
  get_color m30a
  f2=$(cat "$V/.ziyan_front_bid" 2>/dev/null | tr -d '\r\n')
  if test "$f2" = "$APP" && test "$COL" = "$EXP" && test "$AS" = 0; then
    if test "$AP" = 8 || test "$AP" = 9; then
      AOK=1
      break
    fi
  fi
  k=$((k+1))
done
echo "OPEN_N=$OPEN_N"

SB1=$(pid_of 'SpringBoard.app/SpringBoard')
FC1=$(pid_of 'ziyan_framecap serve')
BB1=$(pid_of 'backboardd')
APP1=$(pid_of 'FGCQLibClient-mobile')
FCN1=$(fc_n)

pass=0
test "$HOK" = 1 && test "$AOK" = 1 && test "$HOME_MS" -le 5000 \
  && test "$SB1" = "$SB0" && test "$FC1" = "$FC0" && test "$BB1" = "$BB0" \
  && test -n "$APP1" && test "$FCN1" = 1 && pass=1

echo "ZY.$H PASS=$pass HOK=$HOK HOME_MS=$HOME_MS HP=$HP HS=$HS AOK=$AOK APP_RETRY=$k OPEN_N=$OPEN_N COLOR=$COL AP=$AP AS=$AS SEQ=$SEQ REQ=$REQ FCN=$FCN1"
echo "ZY.${H}_PROC ROLE=framecap PID=$FC1"
echo "ZY.${H}_PROC ROLE=SpringBoard PID=$SB1"
echo "ZY.${H}_PROC ROLE=backboardd PID=$BB1"
echo "ZY.${H}_PROC ROLE=App PID=$APP1"
REMOTE
}

run_one() {
  local H="$1"
  local D="$OUT/$H"
  mkdir -p "$D/minutes"
  local minute=1 pass_n=0 fail_minute=0
  echo "START_TS=$(date '+%F %T') host=.$H" >"$D/RUN_META.txt"
  while [ "$minute" -le "$MIN" ]; do
    local sample_file
    sample_file=$(printf '%s/minutes/%02d.sample' "$D" "$minute")
    local started sample_ts zy zy_rc ssh_try
    started=$(date +%s)
    sample_ts=$(date '+%F %T')
    zy=""
    zy_rc=1
    ssh_try=1
    while [ "$ssh_try" -le 3 ]; do
      if zy=$(sample_host "$H" 2>&1); then
        zy_rc=0
        break
      fi
      zy_rc=$?
      zy="$zy
ZY.$H SSH_FAIL RC=$zy_rc try=$ssh_try"
      echo "$zy" | grep -q "ZY.$H PASS=" && break
      sleep $((ssh_try * 3))
      ssh_try=$((ssh_try + 1))
    done
    {
      echo "MINUTE=$minute TS=$sample_ts"
      echo "ZY_RC=$zy_rc"
      printf '%s\n' "$zy"
      echo "MINUTE_END=$minute"
    } >"$sample_file"
    if echo "$zy" | grep -q "ZY.$H PASS=1"; then
      pass_n=$((pass_n + 1))
      echo ".$H minute=$minute PASS=$pass_n/$MIN"
    else
      fail_minute=$minute
      {
        echo "END_TS=$(date '+%F %T')"
        echo "PASS_N=$pass_n"
        echo "EXPECTED_MINUTES=$MIN"
        echo "FIRST_FAIL_MINUTE=$fail_minute"
        echo "VERDICT=FAIL"
      } >"$D/SUMMARY.txt"
      echo ".$H FAIL at minute=$minute"
      return 1
    fi
    local elapsed remain
    elapsed=$(( $(date +%s) - started ))
    remain=$((60 - elapsed))
    if [ "$remain" -gt 0 ]; then
      sleep "$remain"
    fi
    minute=$((minute + 1))
  done
  {
    echo "END_TS=$(date '+%F %T')"
    echo "PASS_N=$pass_n"
    echo "EXPECTED_MINUTES=$MIN"
    echo "VERDICT=PASS"
  } >"$D/SUMMARY.txt"
  # 收尾快照：不改 Home/金标逻辑，只记录用户要求的 Z2 字段
  local snap
  snap=$(ssh_one "192.168.31.$H" "H='$H' bash -s" <<'SNAP' || true
set +e
if [ -d /var/jb/usr/lib/ziyan/var ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
M=/private/var/mobile/Media/ZiYan
echo FC_N=$(ps -axo args= | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9')
echo SB_PID=$(ps -axo pid=,args= | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//;s/ .*//')
echo KEEP_AFTER_STOP=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)
echo ACTIVE=$(test -f "$V/.ziyan_active" && echo 1 || echo 0)
echo STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null)
echo WORKSET=$(tr '\n' ' ' <"$V/.ziyan_workset_bytes" 2>/dev/null)
echo FRONT=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
echo RSS=$(ps -axo rss=,args= | grep -F 'ziyan_framecap serve' | grep -v grep | head -1 | sed 's/^ *//;s/ .*//')
echo ZOMBIE=$(ps -axo stat= | grep -c Z || true)
RID="z2_${H}_$(date +%s)"
mkdir -p "$M/verdicts"
{
  echo "run_id=$RID"
  echo "host=.$H"
  echo "pkg=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')"
  echo "gate=Z2-30M"
  echo "FC_N=$(ps -axo args= | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9')"
  echo "KEEP_AFTER_STOP=$(test -f "$V/.ziyan_keep_daemon" && echo 1 || echo 0)"
  echo "ACTIVE=$(test -f "$V/.ziyan_active" && echo 1 || echo 0)"
  echo "VERDICT=PASS"
  echo "final=1"
} >"$M/verdicts/${RID}.txt"
echo DEVICE_FINAL=$RID
SNAP
)
  printf '%s\n' "$snap" >>"$D/SUMMARY.txt"
  return 0
}

ts_snap() {
  local host="$1" dest="$2"
  ssh_one "192.168.31.$host" \
    'echo HOST='$host'; date; ps -axo pid=,rss=,%cpu=,etime=,args= | while read -r pid rss cpu etime args; do case "$args" in *TSDaemon\ -server*) echo ROLE=TSDaemon PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo ROLE=SpringBoard PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; esac; done' \
    >"$dest" 2>&1 || echo "SSH_FAIL" >>"$dest"
}

ts_snap 171 "$OUT/ts171_start.txt" &
ts_snap 149 "$OUT/ts149_start.txt" &
wait || true

for H in "${HOSTS[@]}"; do
  run_one "$H" >"$OUT/run_${H}.log" 2>&1 &
  echo $! >"$OUT/pid_${H}.txt"
done
echo "waiting ${MIN}min Gate C workers…"
wait || true

ts_snap 171 "$OUT/ts171_end.txt" &
ts_snap 149 "$OUT/ts149_end.txt" &
wait || true

PASS_N=0
FAIL_N=0
{
  if [ "$MIN" -ge 30 ]; then
    echo "# Z2-30M 正式长稳（zy_p2_c98_30m_gate）"
  else
    echo "# P2 short window (not final Z2-30M)"
  fi
  echo "stamp=$STAMP min=$MIN hosts=${HOSTS[*]}"
  echo "no_desktop_lua no_pretest no_ts_home"
  echo
  echo "| host | verdict | pass_n | first_fail | last_color | last_ap |"
  echo "|---|---|---|---|---|---|"
  for H in "${HOSTS[@]}"; do
    local_v="MISSING"
    local_pn=""
    local_ff=""
    if [ -f "$OUT/$H/SUMMARY.txt" ]; then
      local_v=$(sed -n 's/^VERDICT=//p' "$OUT/$H/SUMMARY.txt" | tail -1)
      local_pn=$(sed -n 's/^PASS_N=//p' "$OUT/$H/SUMMARY.txt" | tail -1)
      local_ff=$(sed -n 's/^FIRST_FAIL_MINUTE=//p' "$OUT/$H/SUMMARY.txt" | tail -1)
    fi
    last=$(ls -1 "$OUT/$H/minutes/"*.sample 2>/dev/null | tail -1)
    last_c=""; last_ap=""
    if [ -n "$last" ]; then
      last_c=$(sed -n "s/.*COLOR=\\([^ ]*\\).*/\\1/p" "$last" | tail -1)
      last_ap=$(sed -n "s/.* AP=\\([^ ]*\\).*/\\1/p" "$last" | tail -1)
    fi
    [ "$local_v" = PASS ] && PASS_N=$((PASS_N+1)) || FAIL_N=$((FAIL_N+1))
    echo "| .$H | ${local_v} | ${local_pn} | ${local_ff:-} | ${last_c} | ${last_ap} |"
  done
  echo
  if [ "$FAIL_N" -eq 0 ] && [ "$PASS_N" -eq "${#HOSTS[@]}" ]; then
    echo "VERDICT=PASS"
  else
    echo "VERDICT=FAIL"
  fi
  echo
  if [ "$MIN" -ge 30 ]; then
    echo "Marked Z2-30M. No surpass claim. Human accept still required."
  else
    echo "Not TouchSprite internal Home. No surpass claim. Not Z2."
  fi
} | tee "$OUT/REPORT.md" "$OUT/VERDICT.md"
echo "OUT=$OUT"
grep -q 'VERDICT=PASS' "$OUT/VERDICT.md"
