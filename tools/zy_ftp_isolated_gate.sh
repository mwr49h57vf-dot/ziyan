#!/usr/bin/env bash
# 隔离 FTP/网络门禁。网络失败不得判本地核心 FAIL。
# 用法: bash tools/zy_ftp_isolated_gate.sh [53 101 112 166]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/Z1_NET_${STAMP}"
mkdir -p "$OUT/ftp_root"
echo "ziyan-ftp-gold-$STAMP" >"$OUT/ftp_root/gold.txt"
if [ "$#" -eq 0 ]; then HOSTS=(53 101 112 166); else HOSTS=("$@"); fi
for h in "${HOSTS[@]}"; do
  case "$h" in 53|101|112|166) ;; *) echo "refuse host=$h"; exit 2 ;; esac
done
HOST_IP="${ZY_FTP_HOST:-$(ipconfig getifaddr en0 2>/dev/null || true)}"
HOST_IP="${HOST_IP:-192.168.31.81}"
PORT="${ZY_FTP_PORT:-2121}"
SSH_KEY_OPTS=(-o BatchMode=yes -o PasswordAuthentication=no -o StrictHostKeyChecking=no
              -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12)
SSH_PW_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
             -o ConnectTimeout=12 -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() {
  local ip="$1"; shift
  if ssh -n "${SSH_KEY_OPTS[@]}" "root@$ip" "true" >/dev/null 2>&1; then
    ssh "${SSH_KEY_OPTS[@]}" "root@$ip" "$@"
  else
    sshpass -p "$PASS" ssh "${SSH_PW_OPTS[@]}" "root@$ip" "$@"
  fi
}
python3 - "$OUT/ftp_root" "$PORT" >"$OUT/ftp_server.log" 2>&1 <<'PY' &
import sys
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer
root, port = sys.argv[1], int(sys.argv[2])
auth = DummyAuthorizer()
auth.add_user("zy", "zytest", root, perm="elradfmwMT")
handler = FTPHandler
handler.authorizer = auth
FTPServer(("0.0.0.0", port), handler).serve_forever()
PY
FTPPID=$!
echo $FTPPID >"$OUT/ftp.pid"
sleep 1
if ! kill -0 "$FTPPID" 2>/dev/null; then
  echo "CLASS=INVALID_RUN reason=ftp_server_not_started" | tee "$OUT/VERDICT.md"
  echo "OUT=$OUT"
  exit 2
fi
echo "OUT=$OUT ftp=$HOST_IP:$PORT pid=$FTPPID hosts=${HOSTS[*]}" | tee "$OUT/meta.txt"

run_one() {
  local H="$1" IP="192.168.31.$1" JB="" VAR
  [ "$H" = 53 ] && JB=/var/jb
  VAR="${JB}/usr/lib/ziyan/var"
  echo "==== NET .$H ===="
  ssh_r "$IP" "H='$H' VAR='$VAR' FTP_HOST='$HOST_IP' PORT='$PORT' bash -s" >"$OUT/raw_${H}.txt" 2>&1 <<'EOS' || true
set +e
M=/private/var/mobile/Media/ZiYan
echo "gold-body-$H" >"$M/_ftp_up.txt"
cat >"$M/_ftp_api.lua" <<LUA
function main()
  local out = "/private/var/mobile/Media/ZiYan/_ftp_api_out.txt"
  local function w(s)
    local f = io.open(out, "a"); if f then f:write(tostring(s).."\\n"); f:close() end
  end
  w("started")
  if type(FtpUpload) ~= "function" then
    w("CLASS=CAPABILITY_MISSING reason=no_FtpUpload")
    w("done")
    return
  end
  local host, user, pass, port = "$FTP_HOST", "zy", "zytest", $PORT
  local up = FtpUpload(host, user, pass, "/private/var/mobile/Media/ZiYan/_ftp_up.txt", "up_${H}.txt", port, 8)
  w("UPLOAD=" .. tostring(up and up.ok) .. " via=" .. tostring(up and up.via or ""))
  local down = FtpDownload(host, user, pass, "gold.txt", "/private/var/mobile/Media/ZiYan/_ftp_down.txt", port, 8)
  w("DOWNLOAD=" .. tostring(down and down.ok) .. " via=" .. tostring(down and down.via or ""))
  local rd = FtpRead(host, user, pass, "gold.txt", port, 8)
  w("READ=" .. tostring(rd and (rd.text or rd.data) or ""))
  local del = FtpDelete(host, user, pass, "up_${H}.txt", port, 8)
  w("DELETE=" .. tostring(del and del.ok))
  local bad = FtpDownload(host, "bad", "bad", "gold.txt", "/private/var/mobile/Media/ZiYan/_ftp_bad.txt", port, 5)
  w("BAD_ACCOUNT=" .. tostring(bad and bad.ok))
  local empty = FtpDownload(host, user, pass, "", "/private/var/mobile/Media/ZiYan/_ftp_empty.txt", port, 5)
  w("EMPTY_PATH=" .. tostring(empty and empty.ok))
  local spec = FtpUpload(host, user, pass, "/private/var/mobile/Media/ZiYan/_ftp_up.txt", "a_b_${H}.txt", port, 5)
  w("SPECIAL=" .. tostring(spec and spec.ok))
  local to = FtpDownload(host, user, pass, "gold.txt", "/private/var/mobile/Media/ZiYan/_ftp_to.txt", 9, 2)
  w("TIMEOUT=" .. tostring(to and to.ok) .. " err=" .. tostring(to and (to.error or "")))
  local disc = FtpDownload("192.0.2.1", user, pass, "gold.txt", "/private/var/mobile/Media/ZiYan/_ftp_disc.txt", 21, 3)
  w("DISCONNECT=" .. tostring(disc and disc.ok) .. " err=" .. tostring(disc and (disc.error or "")))
  local upd = FtpIsUpdate(host, user, pass, "gold.txt", "/private/var/mobile/Media/ZiYan/_ftp_down.txt", port, 8)
  w("ISUPDATE=" .. tostring(upd and upd.ok) .. " updated=" .. tostring(upd and upd.updated))
  w("done")
end
LUA
printf 'ts=1\n' >"$VAR/.ziyan_kill_scripts"; sleep 1
rm -f "$VAR/.ziyan_kill_scripts" "$M/_ftp_api_out.txt"
printf 'path=%s/_ftp_api.lua\nstop=0\n' "$M" >"$VAR/.ziyan_run_intent"
printf '%s/_ftp_api.lua\n' "$M" >"$VAR/.ziyan_embed_script"
echo 1 >"$VAR/.ziyan_embed_on"
echo "nonce=ftp_${H}_$$" >"$VAR/.ziyan_embed_go"
i=0
while [ "$i" -lt 180 ]; do
  [ -s "$M/_ftp_api_out.txt" ] && grep -q '^done$' "$M/_ftp_api_out.txt" && break
  sleep 0.5
  i=$((i+1))
done
if [ -s "$M/_ftp_api_out.txt" ]; then cat "$M/_ftp_api_out.txt"; else echo "CLASS=INVALID_RUN reason=ftp_lua_no_receipt"; fi
printf 'ts=1\n' >"$VAR/.ziyan_kill_scripts"; sleep 1
rm -f "$VAR/.ziyan_kill_scripts" "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_go" \
  "$VAR/.ziyan_embed_script" "$VAR/.ziyan_active" "$M/_ftp_api.lua" "$M/_ftp_api_out.txt"
echo "FC_N=$(ps -axo args= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -dc '0-9')"
echo "FRONT=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)"
echo "ACTIVE=$(test -f "$VAR/.ziyan_active" && echo 1 || echo 0)"
rm -f "$M/_ftp_up.txt" "$M/_ftp_down.txt" "$M/_ftp_bad.txt" "$M/_ftp_empty.txt" "$M/_ftp_to.txt" "$M/_ftp_disc.txt"
EOS
  if [ ! -s "$OUT/raw_${H}.txt" ]; then
    echo "CLASS=INVALID_RUN reason=no_device_net_output host=.$H" | tee "$OUT/run_${H}.txt"
    echo "LOCAL_CORE=unknown"
    return 1
  fi
  local NET=1 LOCAL=1
  if grep -q 'CLASS=INVALID_RUN' "$OUT/raw_${H}.txt"; then
    echo "CLASS=INVALID_RUN host=.$H" | tee "$OUT/run_${H}.txt"
    return 1
  fi
  grep -q '^UPLOAD=true' "$OUT/raw_${H}.txt" || NET=0
  grep -q '^DOWNLOAD=true' "$OUT/raw_${H}.txt" || NET=0
  grep -q 'READ=ziyan-ftp-gold-' "$OUT/raw_${H}.txt" || NET=0
  local FCN VIA
  FCN=$(sed -n 's/^FC_N=//p' "$OUT/raw_${H}.txt" | tail -1)
  VIA=$(sed -n 's/^UPLOAD=true via=//p' "$OUT/raw_${H}.txt" | tail -1)
  [ "${FCN:-0}" = 1 ] || LOCAL=0
  local PKG RID VDICT
  PKG=$(ssh_r "$IP" "dpkg -l com.ziyan.ziyan 2>/dev/null | sed -n 's/^ii  com.ziyan.ziyan  *\\([^ ]*\\).*/\\1/p'" | tr -d '\r')
  RID="net_${H}_$(date +%s)"
  if grep -q 'CAPABILITY_MISSING' "$OUT/raw_${H}.txt"; then VDICT=CAPABILITY_MISSING
  elif [ "$LOCAL" = 1 ] && [ "$NET" = 1 ]; then VDICT=PASS
  elif [ "$LOCAL" = 1 ]; then VDICT=NET_ISOLATED_FAIL
  else VDICT=FAIL
  fi
  {
    echo "run_id=$RID"
    echo "host=.$H"
    echo "pkg=$PKG"
    echo "net_ok=$NET local_core_ok=$LOCAL"
    echo "via=${VIA:-}"
    echo "FC_N=$FCN"
    echo "UPLOAD=$(grep '^UPLOAD=' "$OUT/raw_${H}.txt" | tail -1)"
    echo "DOWNLOAD=$(grep '^DOWNLOAD=' "$OUT/raw_${H}.txt" | tail -1)"
    echo "READ=$(grep '^READ=' "$OUT/raw_${H}.txt" | tail -1)"
    echo "DELETE=$(grep '^DELETE=' "$OUT/raw_${H}.txt" | tail -1)"
    echo "ISUPDATE=$(grep '^ISUPDATE=' "$OUT/raw_${H}.txt" | tail -1)"
    echo "BAD_ACCOUNT=$(grep '^BAD_ACCOUNT=' "$OUT/raw_${H}.txt" | tail -1)"
    echo "TIMEOUT=$(grep '^TIMEOUT=' "$OUT/raw_${H}.txt" | tail -1)"
    echo "DISCONNECT=$(grep '^DISCONNECT=' "$OUT/raw_${H}.txt" | tail -1)"
    echo "VERDICT=$VDICT"
    echo "NOTE=network_fail_does_not_fail_local_core"
    echo "final=1"
  } >"$OUT/device_final_${H}.txt"
  ssh_r "$IP" "mkdir -p /private/var/mobile/Media/ZiYan/verdicts; cat > /private/var/mobile/Media/ZiYan/verdicts/${RID}.txt" \
    <"$OUT/device_final_${H}.txt" || true
  echo "DEVICE_FINAL_$H=$RID VERDICT=$VDICT net=$NET local=$LOCAL" | tee "$OUT/run_${H}.txt"
  # 隔离：仅本地核心失败才让门禁 FAIL
  [ "$LOCAL" = 1 ]
}

PASS_N=0; FAIL_N=0; NET_FAIL=0; NET_PASS=0; CAP_MISS=0
for H in "${HOSTS[@]}"; do
  if run_one "$H"; then PASS_N=$((PASS_N+1)); else FAIL_N=$((FAIL_N+1)); fi
  grep -q 'net=0' "$OUT/run_${H}.txt" 2>/dev/null && NET_FAIL=$((NET_FAIL+1))
  grep -q 'VERDICT=PASS' "$OUT/run_${H}.txt" 2>/dev/null && NET_PASS=$((NET_PASS+1))
  grep -q 'VERDICT=CAPABILITY_MISSING' "$OUT/run_${H}.txt" 2>/dev/null && CAP_MISS=$((CAP_MISS+1))
done
kill "$FTPPID" 2>/dev/null || true
{
  echo "# Z1-NET 隔离 FTP 门禁（Lua Ftp*，非裸 curl）"
  echo "stamp=$STAMP hosts=${HOSTS[*]} ftp=$HOST_IP:$PORT"
  echo "LOCAL_OK_N=$PASS_N LOCAL_FAIL_N=$FAIL_N FTP_PASS_N=$NET_PASS NET_ISOLATED_FAIL=$NET_FAIL CAPABILITY_MISSING=$CAP_MISS"
  echo "network_fail_does_not_fail_local_core"
  echo
  for H in "${HOSTS[@]}"; do
    echo "HOST_$H=$(tr '\n' ' ' <"$OUT/run_${H}.txt" 2>/dev/null)"
  done
  echo
  if [ "$FAIL_N" -ne 0 ]; then
    echo "VERDICT=FAIL"
  elif [ "$NET_PASS" -eq "${#HOSTS[@]}" ]; then
    echo "VERDICT=PASS"
  else
    echo "VERDICT=LOCAL_CORE_PASS_FTP_INCOMPLETE"
    echo "NOTE=do_not_forge_ftp_pass"
  fi
} | tee "$OUT/REPORT.md" "$OUT/VERDICT.md"
echo "OUT=$OUT"
[ "$FAIL_N" -eq 0 ]
