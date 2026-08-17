#!/usr/bin/env bash
# P2 效率：现包 getColor + findMulti P50/P95。不装包、不杀 SB、不启 Desktop lua。
# 用法：bash tools/zy_p2_find_eff_gate.sh [101 112 166]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
SAMPLES="${ZY_P2_EFF_SAMPLES:-24}"
MAX_MS="${ZY_P2_EFF_MAX_MS:-1200}"
APP=com.xztl.ios
EXP=12688231
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P2_FIND_EFF_C98_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o ServerAliveInterval=5)
HOSTS=("$@")
if [ "${#HOSTS[@]}" -eq 0 ]; then HOSTS=(101 112 166); fi

ssh_r() {
  local ip="$1"; shift
  local n
  for n in 1 2 3; do
    sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$ip" "$@" && return 0
    sleep "$n"
  done
  return 1
}

pct() {
  local p="$1"
  sort -n | awk -v p="$p" '
    {a[++n]=$1}
    END{
      if(!n){print -1; exit}
      r=int((p*n+99)/100); if(r<1)r=1; if(r>n)r=n
      print a[r]
    }'
}

echo "stamp=$STAMP samples=$SAMPLES max_ms=$MAX_MS hosts=${HOSTS[*]}" | tee "$OUT/meta.txt"

ALL_OK=1
for host in "${HOSTS[@]}"; do
  dest="$OUT/${host}.txt"
  echo "==== .$host ===="
  if ! ssh_r "192.168.31.$host" "SAMPLES=$SAMPLES APP=$APP EXP=$EXP bash -s" >"$dest" 2>&1 <<'EOS'
set +e
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
V=/usr/lib/ziyan/var
echo 1 >"$V/.ziyan_no_auto_keep"
chmod 666 "$V/.ziyan_no_auto_keep" 2>/dev/null
now_ms() {
  raw="${EPOCHREALTIME-}"
  raw="${raw/./}"
  if printf '%s\n' "$raw" | grep -Eq '^[0-9]{13,}$'; then
    printf '%s\n' "${raw:0:13}"
    return 0
  fi
  return 1
}
elapsed_ms() {
  start="$1"
  now="$(now_ms)" || { echo -1; return; }
  echo $((now-start))
}
line() {
  role="$1"; pat="$2"
  ps -axo pid=,rss=,%cpu=,etime=,args= 2>/dev/null | while read -r pid rss cpu etime args; do
    case "$args" in
      *$pat*) echo "ROLE=$role PID=$pid RSS=$rss CPU=$cpu ETIME=$etime"; break ;;
    esac
  done
}
echo "HOST=$(hostname) TS=$(date +%s)"
echo "VER=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')"
echo "FRONT0=$(tr -d '\r\n' <"$V/.ziyan_front_bid")"
line SpringBoard0 "/System/Library/CoreServices/SpringBoard.app/SpringBoard"
line framecap0 "ziyan_framecap serve"
line App0 "FGCQLibClient-mobile"
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
echo "FRONT1=$(tr -d '\r\n' <"$V/.ziyan_front_bid")"

i=1
while [ "$i" -le "$SAMPLES" ]; do
  rm -f "$V/.ziyan_color_rep"
  n="g${i}_$$"
  printf 'getColor\n706\n449\n%s\n' "$n" >"$V/.ziyan_color_req.tmp"
  t0=$(now_ms) || t0=-1
  mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
  ok=0
  ms=-1
  while :; do
    if [ -f "$V/.ziyan_color_rep" ] && grep -q "$n" "$V/.ziyan_color_rep" 2>/dev/null; then
      ok=1
    fi
    ms=$(elapsed_ms "$t0")
    [ "$ok" = 1 ] && break
    case "$ms" in ''|*[!0-9]*) ms=-1; break ;; esac
    [ "$ms" -ge 2000 ] && break
    sleep 0.02
  done
  col=$(sed -n 3p "$V/.ziyan_color_rep" 2>/dev/null | tr -d '\r')
  ap=$(od -An -t u1 -j 50 -N 1 "$V/.ziyan_frame_shm" 2>/dev/null | tr -d ' \n')
  echo "GET i=$i ok=$ok ms=$ms color=$col ap=$ap"
  i=$((i+1))
done

FIND_JSON='[{"c":12688231,"dx":0,"dy":0,"b":0},{"c":11963216,"dx":1,"dy":2,"b":0},{"c":13873793,"dx":1,"dy":4,"b":0},{"c":14202760,"dx":0,"dy":5,"b":0}]'
i=1
while [ "$i" -le "$SAMPLES" ]; do
  rm -f "$V/.ziyan_color_rep"
  n="f${i}_$$"
  printf 'findMulti\n%s\n90\n706\n449\n707\n454\n%s\n' "$FIND_JSON" "$n" >"$V/.ziyan_color_req.tmp"
  t0=$(now_ms) || t0=-1
  mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
  ok=0
  ms=-1
  while :; do
    if [ -f "$V/.ziyan_color_rep" ] && grep -q "$n" "$V/.ziyan_color_rep" 2>/dev/null; then
      ok=1
    fi
    ms=$(elapsed_ms "$t0")
    [ "$ok" = 1 ] && break
    case "$ms" in ''|*[!0-9]*) ms=-1; break ;; esac
    [ "$ms" -ge 2000 ] && break
    sleep 0.02
  done
  body=$(sed -n 3p "$V/.ziyan_color_rep" 2>/dev/null | tr -d '\r')
  echo "FIND i=$i ok=$ok ms=$ms body=$body"
  i=$((i+1))
done

i=1
while [ "$i" -le 4 ]; do
  rm -f "$V/.ziyan_color_rep"
  n="n${i}_$$"
  printf 'findMulti\n[{"c":12688231,"dx":0,"dy":0,"b":0},{"c":0,"dx":1,"dy":2,"b":0},{"c":16777215,"dx":1,"dy":2,"b":0}]\n100\n706\n449\n707\n454\n%s\n' "$n" >"$V/.ziyan_color_req.tmp"
  t0=$(now_ms) || t0=-1
  mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
  ok=0
  ms=-1
  while :; do
    if [ -f "$V/.ziyan_color_rep" ] && grep -Fq "$n" "$V/.ziyan_color_rep" 2>/dev/null; then
      ok=1
    fi
    ms=$(elapsed_ms "$t0")
    [ "$ok" = 1 ] && break
    case "$ms" in ''|*[!0-9]*) ms=-1; break ;; esac
    [ "$ms" -ge 2000 ] && break
    sleep 0.02
  done
  body=$(sed -n 3p "$V/.ziyan_color_rep" 2>/dev/null | tr -d '\r')
  echo "NEG i=$i ok=$ok ms=$ms body=$body"
  i=$((i+1))
done

echo "FRONT2=$(tr -d '\r\n' <"$V/.ziyan_front_bid")"
line SpringBoard1 "/System/Library/CoreServices/SpringBoard.app/SpringBoard"
line framecap1 "ziyan_framecap serve"
line App1 "FGCQLibClient-mobile"
rm -f "$V/.ziyan_no_auto_keep"
exit 0
EOS
  then
    echo "SSH_OK host=$host"
  else
    echo "SSH_FAIL host=$host" | tee -a "$dest"
    ALL_OK=0
  fi
done

{
  echo "# P2 find efficiency C98"
  echo
  echo "stamp=$STAMP samples=$SAMPLES max_ms=$MAX_MS"
  echo
  echo "| host | get n/ok/color | get P50/P95/max | find n/hit | find P50/P95/max | neg miss | PID stable | verdict |"
  echo "|---|---|---|---|---|---|---|---|"
  for host in "${HOSTS[@]}"; do
    f="$OUT/${host}.txt"
    gn=$(grep -c '^GET ' "$f" 2>/dev/null || echo 0)
    gok=$(grep -c '^GET .* ok=1' "$f" 2>/dev/null || echo 0)
    gcol=$(grep -c "^GET .* color=$EXP" "$f" 2>/dev/null || echo 0)
    gp50=$(sed -n 's/^GET .* ms=\([0-9][0-9]*\).*/\1/p' "$f" | pct 50)
    gp95=$(sed -n 's/^GET .* ms=\([0-9][0-9]*\).*/\1/p' "$f" | pct 95)
    gmax=$(sed -n 's/^GET .* ms=\([0-9][0-9]*\).*/\1/p' "$f" | sort -n | tail -1)
    fn=$(grep -c '^FIND ' "$f" 2>/dev/null || echo 0)
    fhit=$(grep -c '^FIND .*"ok":true' "$f" 2>/dev/null || echo 0)
    fp50=$(sed -n 's/^FIND .* ms=\([0-9][0-9]*\).*/\1/p' "$f" | pct 50)
    fp95=$(sed -n 's/^FIND .* ms=\([0-9][0-9]*\).*/\1/p' "$f" | pct 95)
    fmax=$(sed -n 's/^FIND .* ms=\([0-9][0-9]*\).*/\1/p' "$f" | sort -n | tail -1)
    nn=$(grep -c '^NEG ' "$f" 2>/dev/null || echo 0)
    nmiss=$(grep -c '^NEG .*"ok":false' "$f" 2>/dev/null || echo 0)
    sb0=$(sed -n 's/^ROLE=SpringBoard0 PID=//p' "$f" | awk '{print $1}' | head -1)
    sb1=$(sed -n 's/^ROLE=SpringBoard1 PID=//p' "$f" | awk '{print $1}' | head -1)
    fc0=$(sed -n 's/^ROLE=framecap0 PID=//p' "$f" | awk '{print $1}' | head -1)
    fc1=$(sed -n 's/^ROLE=framecap1 PID=//p' "$f" | awk '{print $1}' | head -1)
    ap0=$(sed -n 's/^ROLE=App0 PID=//p' "$f" | awk '{print $1}' | head -1)
    ap1=$(sed -n 's/^ROLE=App1 PID=//p' "$f" | awk '{print $1}' | head -1)
    pid_ok=0
    [ -n "$sb0" ] && [ "$sb0" = "$sb1" ] && [ "$fc0" = "$fc1" ] && [ "$ap0" = "$ap1" ] && pid_ok=1
    v=FAIL
    if [ "$gok" = "$SAMPLES" ] && [ "$gcol" = "$SAMPLES" ] && \
       [ "$fhit" = "$SAMPLES" ] && [ "$nmiss" = 4 ] && [ "$pid_ok" = 1 ] && \
       [ "${gp95:-9999}" -le "$MAX_MS" ] && [ "${fp95:-9999}" -le "$MAX_MS" ]; then
      v=PASS
    else
      ALL_OK=0
    fi
    echo "| .$host | $gn/$gok/$gcol | ${gp50:--}/${gp95:--}/${gmax:--} | $fn/$fhit | ${fp50:--}/${fp95:--}/${fmax:--} | $nmiss/$nn | $pid_ok | $v |"
    echo ".$host GET_P50=$gp50 GET_P95=$gp95 GET_MAX=$gmax FIND_P50=$fp50 FIND_P95=$fp95 FIND_MAX=$fmax VERDICT=$v" >>"$OUT/numbers.txt"
  done
  echo
  if [ "$ALL_OK" = 1 ]; then
    echo "VERDICT=PASS"
  else
    echo "VERDICT=FAIL"
  fi
  echo
  echo "Notes: daemon color_req path; not TouchSprite internal find; no surpass claim."
} | tee "$OUT/REPORT.md" "$OUT/VERDICT.md"

echo "OUT=$OUT"
grep -q 'VERDICT=PASS' "$OUT/VERDICT.md"
