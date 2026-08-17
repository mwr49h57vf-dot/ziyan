#!/usr/bin/env bash
# P7：C98 与触动同窗对照。.149/.171 只读（activator Home 仅 .171）。
# 不装包、不杀 SB、不启 Desktop lua、不写触动磁盘。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
ROUNDS="${ZY_P7_ROUNDS:-6}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P7_SAMEWIN_C98_${STAMP}"
BASE="$ROOT/tmp_shots/TS171_BIZ_READONLY_${STAMP}"
mkdir -p "$OUT/rounds" "$BASE"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o ServerAliveInterval=5)
ssh_r() {
  local ip="$1"; shift
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$ip" "$@"
}

{
  echo "stamp=$STAMP rounds=$ROUNDS"
  echo "started=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "rule=read_only_ts; no_ziyan_on_149_171; no_desktop_lua"
} | tee "$OUT/meta.txt"

sample_ts() {
  local host="$1" do_home="$2" dest="$3"
  ssh_r "192.168.31.$host" "DO_HOME=$do_home bash -s" >"$dest" 2>&1 <<'EOS' || echo "SSH_FAIL host=$host" >>"$dest"
set +e
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
line() {
  role="$1"
  pat="$2"
  ps -axo pid=,rss=,%cpu=,etime=,args= 2>/dev/null | while read -r pid rss cpu etime args; do
    case "$args" in
      *$pat*) echo "TS ROLE=$role PID=$pid RSS=$rss CPU=$cpu ETIME=$etime"; break ;;
    esac
  done
}
echo "HOST=$(hostname) TS=$(date +%s)"
line TSDaemon "TSDaemon -server"
line Hades "/Hades "
line SpringBoard "SpringBoard.app/SpringBoard"
line App "FGCQLibClient-mobile"
echo "RUNCFG=$(tr '\n' ' ' < /var/mobile/Media/TouchSprite/config/run.cfg 2>/dev/null | head -c 160)"
echo "HTTP=$(wget -qO- -T2 http://127.0.0.1:50005/status 2>/dev/null | tr '\n' ' ' | head -c 80)"
if [ "$DO_HOME" = 1 ]; then
  t0=$(date +%s)
  activator send libactivator.system.homebutton >/dev/null 2>&1 \
    || uiopen 'activator://libactivator.system.homebutton' >/dev/null 2>&1 || true
  sleep 1
  uiopen 'com.xztl.ios://' >/dev/null 2>&1 || true
  sleep 1
  echo "HOME_MS=$(( ($(date +%s) - t0) * 1000 ))"
  line SpringBoardAfter "SpringBoard.app/SpringBoard"
  line AppAfter "FGCQLibClient-mobile"
fi
EOS
}

sample_zy() {
  local host="$1" do_home="$2" dest="$3"
  ssh_r "192.168.31.$host" "DO_HOME=$do_home bash -s" >"$dest" 2>&1 <<'EOS' || echo "SSH_FAIL host=$host" >>"$dest"
set +e
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
V=/usr/lib/ziyan/var
APP=com.xztl.ios
EXP=12688231
echo "HOST=zy TS=$(date +%s)"
echo "VER=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')"
echo "FRONT0=$(tr -d '\r\n' <"$V/.ziyan_front_bid")"
line() {
  role="$1"
  pat="$2"
  ps -axo pid=,rss=,%cpu=,etime=,args= 2>/dev/null | while read -r pid rss cpu etime args; do
    case "$args" in
      *$pat*) echo "ZY ROLE=$role PID=$pid RSS=$rss CPU=$cpu ETIME=$etime"; break ;;
    esac
  done
}
line SpringBoard "/System/Library/CoreServices/SpringBoard.app/SpringBoard"
line framecap "ziyan_framecap serve"
line App "FGCQLibClient-mobile"
if [ "$DO_HOME" != 1 ]; then
  exit 0
fi
rm -f "$V/.ziyan_open_app"
t0=$(date +%s)
printf '1\n' >"$V/.ziyan_go_home"
chmod 666 "$V/.ziyan_go_home" 2>/dev/null
i=0; HOK=0
while test "$i" -lt 80; do
  f=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
  echo "$f" | grep -qi springboard && { HOK=1; break; }
  sleep 0.05
  i=$((i+1))
done
echo "HOME_OK=$HOK"
echo "HOME_MS=$(( ($(date +%s) - t0) * 1000 ))"
echo "FRONT_H=$(tr -d '\r\n' <"$V/.ziyan_front_bid")"
rm -f "$V/.ziyan_go_home"
sleep 0.8
k=0; AOK=0; COL=; AP=; CMS=-1
while test "$k" -lt 8; do
  printf '%s\n' "$APP" >"$V/.ziyan_open_app"
  chmod 666 "$V/.ziyan_open_app" 2>/dev/null
  sleep 1.0
  rm -f "$V/.ziyan_open_app"
  sleep 0.6
  n=p7_${k}_$$
  rm -f "$V/.ziyan_color_rep"
  ct0=$(date +%s)
  printf 'getColor\n706\n449\n%s\n' "$n" >"$V/.ziyan_color_req.tmp"
  mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
  q=0
  while test "$q" -lt 80; do
    test -f "$V/.ziyan_color_rep" && grep -q "$n" "$V/.ziyan_color_rep" && break
    sleep 0.05
    q=$((q+1))
  done
  CMS=$(( ($(date +%s) - ct0) * 1000 ))
  COL=$(sed -n 3p "$V/.ziyan_color_rep" 2>/dev/null)
  AP=$(od -An -t u1 -j 50 -N 1 "$V/.ziyan_frame_shm" 2>/dev/null | tr -d ' \n')
  f2=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
  if test "$f2" = "$APP" && test "$COL" = "$EXP" && test "$AP" = 8; then
    AOK=1
    break
  fi
  k=$((k+1))
done
echo "AOK=$AOK"
echo "COLOR=$COL"
echo "AP=$AP"
echo "COLOR_MS=$CMS"
echo "RETRY=$k"
echo "FRONT1=$f2"
line SpringBoard1 "/System/Library/CoreServices/SpringBoard.app/SpringBoard"
line framecap1 "ziyan_framecap serve"
EOS
}

r=1
while test "$r" -le "$ROUNDS"; do
  rd=$(printf '%s/rounds/%02d' "$OUT" "$r")
  mkdir -p "$rd"
  echo "==== ROUND $r / $ROUNDS $(date '+%T') ===="
  sample_ts 171 1 "$rd/ts171.txt" &
  p171=$!
  sample_ts 149 0 "$rd/ts149.txt" &
  p149=$!
  sample_zy 101 1 "$rd/zy101.txt" &
  p101=$!
  sample_zy 112 0 "$rd/zy112.txt" &
  p112=$!
  sample_zy 166 0 "$rd/zy166.txt" &
  p166=$!
  wait $p171 $p149 $p101 $p112 $p166 || true
  {
    echo "ROUND=$r TS=$(date +%s)"
    echo "--- 171 ---"; grep -E 'ROLE=|HOME_MS=|SSH_FAIL|RUNCFG|HTTP=' "$rd/ts171.txt" | head -12
    echo "--- 149 ---"; grep -E 'ROLE=|SSH_FAIL|RUNCFG=' "$rd/ts149.txt" | head -8
    echo "--- 101 ---"; grep -E 'ROLE=|HOME_|AOK=|COLOR=|SSH_FAIL|VER=' "$rd/zy101.txt" | head -14
    echo "--- 112 ---"; grep -E 'ROLE=|FRONT0=|SSH_FAIL|VER=' "$rd/zy112.txt" | head -8
    echo "--- 166 ---"; grep -E 'ROLE=|FRONT0=|SSH_FAIL|VER=' "$rd/zy166.txt" | head -8
  } | tee "$rd/SUMMARY.txt"
  r=$((r+1))
  if test "$r" -le "$ROUNDS"; then sleep 8; fi
done

# assemble
{
  echo "# P7 same-window C98 vs TouchSprite"
  echo
  echo "stamp=$STAMP rounds=$ROUNDS"
  echo
  echo "| round | TS171 TSDaemon | TS171 SB | TS171 Home_ms | ZY101 Home_ok/ms | ZY101 color | ZY101 AP |"
  echo "|---|---|---|---|---|---|---|"
  r=1
  zy_home_ok=0
  zy_color_ok=0
  ts_alive=0
  zy_ssh_fail=0
  ts_ssh_fail=0
  while test "$r" -le "$ROUNDS"; do
    rd=$(printf '%s/rounds/%02d' "$OUT" "$r")
    tsd=$(sed -n 's/.*ROLE=TSDaemon PID=\([0-9]*\).*/\1/p' "$rd/ts171.txt" | head -1)
    tssb=$(sed -n 's/.*ROLE=SpringBoard PID=\([0-9]*\).*/\1/p' "$rd/ts171.txt" | head -1)
    thm=$(sed -n 's/^HOME_MS=//p' "$rd/ts171.txt" | head -1)
    hok=$(sed -n 's/^HOME_OK=//p' "$rd/zy101.txt" | head -1)
    hms=$(sed -n 's/^HOME_MS=//p' "$rd/zy101.txt" | head -1)
    aok=$(sed -n 's/^AOK=//p' "$rd/zy101.txt" | head -1)
    col=$(sed -n 's/^COLOR=//p' "$rd/zy101.txt" | head -1)
    ap=$(sed -n 's/^AP=//p' "$rd/zy101.txt" | head -1)
    grep -q SSH_FAIL "$rd/ts171.txt" && ts_ssh_fail=$((ts_ssh_fail+1))
    grep -q SSH_FAIL "$rd/zy101.txt" && zy_ssh_fail=$((zy_ssh_fail+1))
    [ -n "$tsd" ] && ts_alive=$((ts_alive+1))
    [ "$hok" = 1 ] && zy_home_ok=$((zy_home_ok+1))
    [ "$aok" = 1 ] && [ "$col" = 12688231 ] && zy_color_ok=$((zy_color_ok+1))
    echo "| $r | ${tsd:--} | ${tssb:--} | ${thm:--} | ${hok:--}/${hms:--} | ${col:--} aok=${aok:--} | ${ap:--} |"
    r=$((r+1))
  done
  echo
  echo "TS171_alive_rounds=$ts_alive/$ROUNDS ZY101_home_ok=$zy_home_ok/$ROUNDS ZY101_color_ok=$zy_color_ok/$ROUNDS"
  echo "ts_ssh_fail=$ts_ssh_fail zy_ssh_fail=$zy_ssh_fail"
  echo
  echo "Notes:"
  echo "- TouchSprite find 内部耗时不可从 HTTP/外部模板读取；本对照是进程稳态 + Home 可完成 + 子砚标准色。"
  echo "- 禁宣称超越触动。"
  VERDICT=FAIL
  if [ "$ts_alive" = "$ROUNDS" ] && [ "$zy_home_ok" = "$ROUNDS" ] && \
     [ "$zy_color_ok" = "$ROUNDS" ] && [ "$ts_ssh_fail" = 0 ] && [ "$zy_ssh_fail" = 0 ]; then
    VERDICT=COMPARISON_COMPLETE
  fi
  echo "VERDICT=$VERDICT"
} | tee "$OUT/COMPARE.md" "$OUT/VERDICT.md"

# P8-compatible baseline pointer
{
  echo '{'
  echo "  \"stamp\": \"$STAMP\","
  echo "  \"host\": \"171\","
  echo "  \"kind\": \"same_window_c98\","
  echo "  \"rounds\": $ROUNDS,"
  echo "  \"compare\": \"$OUT\","
  echo "  \"ts_script\": \"main.lua\","
  echo "  \"note\": \"process/Home/color paired; not TS internal find latency\""
  echo '}'
} >"$BASE/summary.json"
cp "$OUT/COMPARE.md" "$BASE/COMPARE.md"
echo "OUT=$OUT"
echo "BASE=$BASE"
grep -q 'VERDICT=COMPARISON_COMPLETE' "$OUT/VERDICT.md"
