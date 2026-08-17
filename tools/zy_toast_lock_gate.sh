#!/usr/bin/env bash
# C98 Toast + 锁屏/解锁现包门禁。不装包、不杀 SB、不启 Desktop ios7/ios8p。
# 只跑 .101/.112/.166。找色只作解锁后前台恢复抽检，不参与 Toast 判定。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
HOST="${1:-}"
case "$HOST" in
  101|112|166) ;;
  *) echo "usage: $0 <101|112|166>" >&2; exit 2 ;;
esac
IP="192.168.31.$HOST"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/TOAST_LOCK_GATE_${STAMP}_${HOST}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=15 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o ServerAliveInterval=5)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$IP" "$@"; }

VISUAL="$ROOT/tools/zy_toast_visual_gate.swift"
{
  echo "host=$HOST ip=$IP"
  echo "started=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "package_expected=C-65.11-98"
} | tee "$OUT/meta.txt"

ssh_r 'bash -s' >"$OUT/device.tsv" 2>"$OUT/device.stderr" <<'REMOTE'
set +e
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
V=/usr/lib/ziyan/var
APP=com.xztl.ios
EXP=12688231
date +%s >"$V/.ziyan_project_active"
date +%s >"$V/.ziyan_script_session"
printf '1\n' >"$V/.ziyan_orient"
chmod 666 "$V/.ziyan_project_active" "$V/.ziyan_script_session" "$V/.ziyan_orient" 2>/dev/null
echo "version=$(dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p')"
echo "front0=$(tr -d '\r\n' <"$V/.ziyan_front_bid")"
echo "SB0=$(ps -axo pid=,args= | grep '/System/Library/CoreServices/SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//;s/ .*//')"
echo "FC0=$(ps -axo pid=,args= | grep '[z]iyan_framecap serve' | grep -v grep | head -1 | sed 's/^ *//;s/ .*//')"

show_toast() {
  tag="$1"
  printf 'toast\n%s\n2500\n1\n' "$tag" >"$V/.ziyan_cmd.tmp"
  chmod 666 "$V/.ziyan_cmd.tmp" 2>/dev/null
  mv "$V/.ziyan_cmd.tmp" "$V/.ziyan_cmd"
}

wait_toast() {
  tag="$1"
  i=0
  while test "$i" -lt 40; do
    if grep -q '^phase=visible_commit ' "$V/.ziyan_toast_dump" 2>/dev/null &&
       grep -Fqx "text=$tag" "$V/.ziyan_toast_dump" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    i=$((i+1))
  done
  return 1
}

save_dump() {
  name="$1"
  cp "$V/.ziyan_toast_dump" "/tmp/zy_toast_${name}.dump" 2>/dev/null || true
}

printf '%s\n' "$APP" >"$V/.ziyan_open_app"
chmod 666 "$V/.ziyan_open_app" 2>/dev/null
sleep 1.5
rm -f "$V/.ziyan_open_app"
show_toast ZYC98APP
if wait_toast ZYC98APP; then echo APP_TOAST=1; else echo APP_TOAST=0; fi
save_dump app
echo "APP_FRONT=$(tr -d '\r\n' <"$V/.ziyan_front_bid")"
echo "APP_HIDDEN=$(sed -n 's/.* hidden=\([01]\).*/\1/p' "$V/.ziyan_toast_dump" | head -1)"
echo "APP_LOCK=$(tr ' ;' '\n' <"$V/.ziyan_toast_dump" | sed -n 's/^toastLock=//p' | head -1)"

rm -f "$V/.ziyan_open_app"
printf '1\n' >"$V/.ziyan_go_home"
chmod 666 "$V/.ziyan_go_home" 2>/dev/null
i=0; HOK=0
while test "$i" -lt 80; do
  f=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
  echo "$f" | grep -qi springboard && { HOK=1; break; }
  sleep 0.05
  i=$((i+1))
done
sleep 1
rm -f "$V/.ziyan_go_home"
echo "HOME_OK=$HOK"
echo "HOME_FRONT=$(tr -d '\r\n' <"$V/.ziyan_front_bid")"
show_toast ZYC98HOME
if wait_toast ZYC98HOME; then echo HOME_TOAST=1; else echo HOME_TOAST=0; fi
save_dump home
echo "HOME_HIDDEN=$(sed -n 's/.* hidden=\([01]\).*/\1/p' "$V/.ziyan_toast_dump" | head -1)"

rm -f "$V/.ziyan_lock_rep" "$V/.ziyan_lock_state"
printf '1\n' >"$V/.ziyan_lock_req"
chmod 666 "$V/.ziyan_lock_req" 2>/dev/null
i=0; LOCK=0
while test "$i" -lt 30; do
  if [ -s "$V/.ziyan_lock_rep" ]; then
    head -1 "$V/.ziyan_lock_rep" | grep -q '^ok$' && LOCK=1
    break
  fi
  sleep 0.2
  i=$((i+1))
done
echo "LOCK_OK=$LOCK"
echo "LOCK_REP=$(tr '\n' '|' <"$V/.ziyan_lock_rep" 2>/dev/null)"
echo "LOCK_STATE=$(tr -d '\r\n' <"$V/.ziyan_lock_state" 2>/dev/null)"
sleep 1

rm -f "$V/.ziyan_unlock_rep"
printf '1\n' >"$V/.ziyan_unlock_req"
chmod 666 "$V/.ziyan_unlock_req" 2>/dev/null
i=0; UNLOCK=0
while test "$i" -lt 30; do
  if [ -s "$V/.ziyan_unlock_rep" ]; then
    head -1 "$V/.ziyan_unlock_rep" | grep -q '^ok$' && UNLOCK=1
    break
  fi
  sleep 0.2
  i=$((i+1))
done
echo "UNLOCK_OK=$UNLOCK"
echo "UNLOCK_REP=$(tr '\n' '|' <"$V/.ziyan_unlock_rep" 2>/dev/null)"
echo "WAKE=$(tail -3 "$V/.ziyan_wake_log" 2>/dev/null | tr '\n' '|')"
sleep 1.2

show_toast ZYC98ULK
if wait_toast ZYC98ULK; then echo ULK_TOAST=1; else echo ULK_TOAST=0; fi
save_dump ulk
echo "ULK_FRONT=$(tr -d '\r\n' <"$V/.ziyan_front_bid")"
echo "ULK_HIDDEN=$(sed -n 's/.* hidden=\([01]\).*/\1/p' "$V/.ziyan_toast_dump" | head -1)"

k=0; AOK=0; COL=; AP=
while test "$k" -lt 12; do
  printf '%s\n' "$APP" >"$V/.ziyan_open_app"
  chmod 666 "$V/.ziyan_open_app" 2>/dev/null
  sleep 1.2
  rm -f "$V/.ziyan_open_app"
  sleep 0.7
  n=tl_${k}_$$
  rm -f "$V/.ziyan_color_rep"
  printf 'getColor\n706\n449\n%s\n' "$n" >"$V/.ziyan_color_req.tmp"
  mv "$V/.ziyan_color_req.tmp" "$V/.ziyan_color_req"
  q=0
  while test "$q" -lt 60; do
    test -f "$V/.ziyan_color_rep" && grep -q "$n" "$V/.ziyan_color_rep" && break
    sleep 0.05
    q=$((q+1))
  done
  COL=$(sed -n 3p "$V/.ziyan_color_rep" 2>/dev/null)
  AP=$(od -An -t u1 -j 50 -N 1 "$V/.ziyan_frame_shm" 2>/dev/null | tr -d ' \n')
  f2=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
  if test "$f2" = "$APP" && test "$COL" = "$EXP" && test "$AP" = 8; then
    AOK=1
    break
  fi
  k=$((k+1))
done
echo "RECOVER_AOK=$AOK"
echo "COLOR=$COL"
echo "AP=$AP"
echo "FRONT=$f2"
echo "RETRY=$k"
show_toast ZYC98APP2
if wait_toast ZYC98APP2; then echo APP2_TOAST=1; else echo APP2_TOAST=0; fi
save_dump app2
echo "APP2_HIDDEN=$(sed -n 's/.* hidden=\([01]\).*/\1/p' "$V/.ziyan_toast_dump" | head -1)"
echo "SB1=$(ps -axo pid=,args= | grep '/System/Library/CoreServices/SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//;s/ .*//')"
echo "FC1=$(ps -axo pid=,args= | grep '[z]iyan_framecap serve' | grep -v grep | head -1 | sed 's/^ *//;s/ .*//')"
echo "FC_N=$(ps -axo args= | grep '[z]iyan_framecap serve' | grep -v grep | wc -l | tr -dc '0-9')"
REMOTE

for n in app home ulk app2; do
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" "root@$IP:/tmp/zy_toast_${n}.dump" "$OUT/${n}.dump" 2>/dev/null || true
done

ssh_r 'bash -s' >>"$OUT/device.tsv" 2>>"$OUT/device.stderr" <<'SNAP'
set +e
V=/usr/lib/ziyan/var
printf '1\n' >"$V/.ziyan_go_home"
chmod 666 "$V/.ziyan_go_home" 2>/dev/null
i=0
while test "$i" -lt 40; do
  tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null | grep -qi springboard && break
  sleep 0.05
  i=$((i+1))
done
rm -f "$V/.ziyan_go_home"
printf 'toast\nZYC98VIS\n3000\n1\n' >"$V/.ziyan_cmd.tmp"
chmod 666 "$V/.ziyan_cmd.tmp" 2>/dev/null
mv "$V/.ziyan_cmd.tmp" "$V/.ziyan_cmd"
i=0
while test "$i" -lt 30; do
  if grep -q '^phase=visible_commit ' "$V/.ziyan_toast_dump" 2>/dev/null &&
     grep -Fqx 'text=ZYC98VIS' "$V/.ziyan_toast_dump" 2>/dev/null; then
    echo VIS_TOAST=1
    break
  fi
  sleep 0.1
  i=$((i+1))
done
test "$i" -lt 30 || echo VIS_TOAST=0
SNAP
curl -sS -m 12 -o "$OUT/home_toast.png" "http://$IP:50005/snapshot" >"$OUT/home_toast.http" 2>&1 || true
file "$OUT/home_toast.png" >"$OUT/home_toast.file" 2>&1 || true
VISUAL_VERDICT=SKIP
if [ -s "$VISUAL" ] && [ -s "$OUT/home_toast.png" ] && command -v swift >/dev/null; then
  swift "$VISUAL" "$OUT/home_toast.png" "ZYC98VIS|ZYC98HOME" >"$OUT/visual.txt" 2>&1 || true
  VISUAL_VERDICT=$(sed -n 's/^VISUAL_VERDICT=//p' "$OUT/visual.txt" | tail -1)
  VISUAL_VERDICT="${VISUAL_VERDICT:-SKIP}"
fi
echo "VISUAL_VERDICT=$VISUAL_VERDICT" | tee -a "$OUT/device.tsv"

ssh_r "printf '%s\n' com.xztl.ios > /usr/lib/ziyan/var/.ziyan_open_app; chmod 666 /usr/lib/ziyan/var/.ziyan_open_app" >/dev/null 2>&1 || true

field() { sed -n "s/^$1=//p" "$OUT/device.tsv" | tail -1; }
APP_TOAST=$(field APP_TOAST)
HOME_TOAST=$(field HOME_TOAST)
HOME_OK=$(field HOME_OK)
LOCK_OK=$(field LOCK_OK)
UNLOCK_OK=$(field UNLOCK_OK)
ULK_TOAST=$(field ULK_TOAST)
APP2_TOAST=$(field APP2_TOAST)
RECOVER=$(field RECOVER_AOK)
APP_HIDDEN=$(field APP_HIDDEN)
HOME_HIDDEN=$(field HOME_HIDDEN)
ULK_HIDDEN=$(field ULK_HIDDEN)
APP_LOCK=$(field APP_LOCK)
SB0=$(field SB0)
SB1=$(field SB1)
FC0=$(field FC0)
FC1=$(field FC1)
VISUAL_REASON=$(sed -n 's/^VISUAL_REASON=//p' "$OUT/visual.txt" 2>/dev/null | tail -1)

GAME_LOCK_BAD=0
[ "$APP_LOCK" = 1 ] && GAME_LOCK_BAD=1
VISUAL_FAIL=0
if [ "$VISUAL_VERDICT" = FAIL ] && [ "$VISUAL_REASON" = position ]; then
  VISUAL_FAIL=1
fi

VERDICT=FAIL
if [ "$APP_TOAST" = 1 ] && [ "$HOME_TOAST" = 1 ] && [ "$HOME_OK" = 1 ] &&
   [ "$LOCK_OK" = 1 ] && [ "$UNLOCK_OK" = 1 ] && [ "$ULK_TOAST" = 1 ] &&
   [ "$APP2_TOAST" = 1 ] && [ "$RECOVER" = 1 ] &&
   [ "$APP_HIDDEN" != 1 ] && [ "$HOME_HIDDEN" != 1 ] && [ "$ULK_HIDDEN" != 1 ] &&
   [ "$GAME_LOCK_BAD" = 0 ] && [ "$VISUAL_FAIL" = 0 ] &&
   [ -n "$SB0" ] && [ "$SB0" = "$SB1" ] && [ -n "$FC0" ] && [ "$FC0" = "$FC1" ]; then
  VERDICT=PASS
fi

{
  echo "# Toast/Lock gate .$HOST"
  echo "APP_TOAST=$APP_TOAST HOME_TOAST=$HOME_TOAST HOME_OK=$HOME_OK LOCK_OK=$LOCK_OK UNLOCK_OK=$UNLOCK_OK ULK_TOAST=$ULK_TOAST APP2_TOAST=$APP2_TOAST RECOVER=$RECOVER"
  echo "hidden app=$APP_HIDDEN home=$HOME_HIDDEN ulk=$ULK_HIDDEN toastLock_app=$APP_LOCK visual=$VISUAL_VERDICT reason=$VISUAL_REASON"
  echo "SB $SB0->$SB1 FC $FC0->$FC1"
  echo "VERDICT=$VERDICT"
  echo "OUT=$OUT"
} | tee "$OUT/VERDICT.md"

grep -q 'VERDICT=PASS' "$OUT/VERDICT.md"
