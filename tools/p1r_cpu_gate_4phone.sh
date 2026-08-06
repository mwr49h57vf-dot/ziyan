#!/usr/bin/env bash
# Phase1-R CPU/内存硬门禁 · 8-161-113（过程采样 → 阈值）
# 对照：idle 无脚本时 framecap 应远低于 .171 跑脚本时的 TSDaemon
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tmp_shots/P1R_CPU_GATE_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
PASS=0; FAIL=0
note() { echo "$*" | tee -a "$OUT/summary.txt"; }
ok() { PASS=$((PASS+1)); note "PASS $*"; }
bad() { FAIL=$((FAIL+1)); note "FAIL $*"; }

ssh_r() {
  local ip=$1; shift
  sshpass -p alpine ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no -o ConnectTimeout=12 "root@$ip" "$@"
}

hard_idle() {
  local ip=$1 VAR=$2
  ssh_r "$ip" "touch $VAR/.ziyan_user_stopped; printf 'ts=1\n' > $VAR/.ziyan_kill_scripts; chmod 666 $VAR/.ziyan_user_stopped $VAR/.ziyan_kill_scripts 2>/dev/null; sleep 2; rm -f $VAR/.ziyan_embed_go $VAR/.ziyan_embed_on $VAR/.ziyan_embed_script $VAR/.ziyan_embed_alive $VAR/.ziyan_lua_embedded $VAR/.ziyan_script_session $VAR/.ziyan_project_active $VAR/.ziyan_find_pulse $VAR/.ziyan_te_running $VAR/.ziyan_kill_scripts $VAR/.ziyan_force_recap $VAR/.ziyan_frame_req $VAR/.ziyan_snap_http_want; printf 'state=idle\npath=\norient=-1\ngen=0\n' > $VAR/.ziyan_session; printf 'stop=1\n' > $VAR/.ziyan_run_intent; chmod 666 $VAR/.ziyan_session $VAR/.ziyan_run_intent; rm -f $VAR/.ziyan_user_stopped" || true
}

# 读 framecap %cpu rss（第二次采样更稳）；shm 字节
sample_fc() {
  local ip=$1 VAR=$2
  ssh_r "$ip" "
    sleep 2
    line=\$(ps -A -o pid=,%cpu=,rss=,args= 2>/dev/null | grep 'ziyan_framecap serve' | grep -v grep | head -1)
    echo \"LINE1=\$line\"
    sleep 3
    line=\$(ps -A -o pid=,%cpu=,rss=,args= 2>/dev/null | grep 'ziyan_framecap serve' | grep -v grep | head -1)
    echo \"LINE2=\$line\"
    sz=\$(wc -c < $VAR/.ziyan_frame_shm 2>/dev/null || echo 0)
    echo \"SHM=\$sz\"
    fc=\$(ps -A -o %cpu=,args= 2>/dev/null | grep ziyan_fscloakd | grep -v grep | head -1 | sed 's/^ *//' | cut -d' ' -f1)
    echo \"FSCLOAK_CPU=\${fc:-0}\"
  "
}

check() {
  local ip=$1 tag=$2 rootless=$3
  local VAR
  if [ "$rootless" = 1 ]; then VAR=/var/jb/usr/lib/ziyan/var; else VAR=/usr/lib/ziyan/var; fi
  note "==== .$tag $ip CPU/MEM ===="
  local ver; ver=$(ssh_r "$ip" "dpkg -l com.ziyan.ziyan 2>/dev/null | tail -1" || true)
  echo "$ver" >"$OUT/${tag}_ver.txt"
  echo "$ver" | grep -q '8-161-115' && ok "$tag ver 115" || bad "$tag ver ($ver)"

  hard_idle "$ip" "$VAR"
  sleep 6  # 等 cold_idle shm_clear（≤5s）

  local samp; samp=$(sample_fc "$ip" "$VAR" || true)
  echo "$samp" >"$OUT/${tag}_sample.txt"
  note "$samp"

  # parse LINE2（ps 列宽不固定）
  printf '%s\n' "$samp" | python3 -c '
import sys,re
text=sys.stdin.read()
line=""; shm="0"
for ln in text.splitlines():
    if ln.startswith("LINE2="): line=ln[6:].strip()
    if ln.startswith("SHM="): shm=(ln[4:].strip() or "0")
parts=re.split(r"\s+", line.strip()) if line else []
cpu=parts[1] if len(parts)>=3 else "99"
rss=parts[2] if len(parts)>=3 else "999999"
open(sys.argv[1],"w").write("cpu=%s\nrss=%s\nshm=%s\n"%(cpu,rss,shm))
ok_cpu=float(cpu)<=2.5
ok_rss=int(float(rss))<=40960
ok_shm=int(float(shm) or 0)<=131072
open(sys.argv[2],"w").write("cpu=%d\nrss=%d\nshm=%d\n"%(ok_cpu,ok_rss,ok_shm))
print(cpu, rss, shm)
' "$OUT/${tag}_nums.txt" "$OUT/${tag}_okflags.txt"
  local cpu rss shm
  cpu=$(sed -n 's/^cpu=//p' "$OUT/${tag}_nums.txt")
  rss=$(sed -n 's/^rss=//p' "$OUT/${tag}_nums.txt")
  shm=$(sed -n 's/^shm=//p' "$OUT/${tag}_nums.txt")
  note "nums cpu=$cpu rss_kb=$rss shm=$shm"
  grep -q '^cpu=1' "$OUT/${tag}_okflags.txt" && ok "$tag framecap CPU<=2.5% ($cpu)" || bad "$tag framecap CPU=$cpu"
  grep -q '^rss=1' "$OUT/${tag}_okflags.txt" && ok "$tag framecap RSS<=40MB ($rss KB)" || bad "$tag framecap RSS=$rss"
  grep -q '^shm=1' "$OUT/${tag}_okflags.txt" && ok "$tag shm<=128KB ($shm)" || bad "$tag shm=$shm (full frame leak?)"

  # session idle
  local sess; sess=$(ssh_r "$ip" "tr '\n' ' ' < $VAR/.ziyan_session" || true)
  echo "$sess" | grep -q state=idle && ok "$tag session idle" || bad "$tag session ($sess)"

  # status wants_run=0
  local st=""
  st=$(curl -sS -m 5 "http://$ip:50005/status" 2>/dev/null || echo "")
  echo "${st}" >"$OUT/${tag}_status.txt"
  echo "${st}" | grep -qE 'wants_run=0|"wants_run":false' && ok "$tag wants_run=0" || bad "$tag wants_run (${st})"
}

check 192.168.31.53 53 1
check 192.168.31.101 101 0
check 192.168.31.112 112 0
check 192.168.31.166 166 0

note "==== TOTAL pass=$PASS fail=$FAIL out=$OUT ===="
[ "$FAIL" -eq 0 ]
