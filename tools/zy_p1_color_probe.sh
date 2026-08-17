#!/usr/bin/env bash
# P1/P2 四机业务色链诊断：同一前台帧上直接 getColor，再用 Desktop 脚本的
# 原始色串/ROI find。用于区分素材差异、取色映射差异和匹配路径差异。
# 用法：bash tools/zy_p1_color_probe.sh [all|53|101|112|166]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
WANT="${1:-all}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P1_COLOR_PROBE_$STAMP"
mkdir -p "$OUT"

PASS_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
           -o ConnectTimeout=15 -o PreferredAuthentications=password
           -o PubkeyAuthentication=no -o ServerAliveInterval=20
           -o ServerAliveCountMax=6)
KEY_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=15 -o BatchMode=yes -o ServerAliveInterval=20
          -o ServerAliveCountMax=6)
AUTH=""

init_auth() {
  local ip="$1"
  if sshpass -p "$PASS" ssh "${PASS_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    AUTH=password
  elif ssh -n "${KEY_OPTS[@]}" "root@$ip" true >/dev/null 2>&1; then
    AUTH=key
  else
    echo "FATAL ssh_auth_failed ip=$ip" >&2
    return 1
  fi
  echo "SSH_AUTH=$AUTH ip=$ip"
}

ssh_r() {
  local ip="$1"; shift
  local n
  for n in 1 2 3; do
    if [ "$AUTH" = password ]; then
      sshpass -p "$PASS" ssh "${PASS_OPTS[@]}" "root@$ip" "$@" && return 0
    else
      ssh -n "${KEY_OPTS[@]}" "root@$ip" "$@" && return 0
    fi
    sleep "$n"
  done
  return 1
}

run_one() {
  local tag="$1" ip="$2" scheme="$3" script="$4"
  local var="/usr/lib/ziyan/var"
  [ "$scheme" = rootless ] && var="/var/jb/usr/lib/ziyan/var"
  local media="/private/var/mobile/Media/ZiYan"

  echo "==== P1_COLOR_PROBE .$tag script=$script ===="
  init_auth "$ip"
  ssh_r "$ip" "VAR='$var' MEDIA='$media' SCRIPT='$script' bash -s" <<'EOS' \
    | tee "$OUT/gate_${tag}.txt"
set +e
mkdir -p "$VAR" "$MEDIA"
printf 'ts=1\n' >"$VAR/.ziyan_kill_scripts"
sleep 1
rm -f "$VAR/.ziyan_kill_scripts" "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" \
  "$VAR/.ziyan_embed_go" "$VAR/.ziyan_active" "$MEDIA/_p1_color_probe_out.txt"
echo 1 >"$VAR/.ziyan_no_auto_keep"
echo 1 >"$VAR/.ziyan_embed_on"

# 先回桌面并等待 shm 的真实前台对齐，禁从上一个 App 的旧帧下结论。
for i in 1 2 3 4 5 6; do
  echo 1 >"$VAR/.ziyan_go_home"
  sleep 0.7
  rm -f "$VAR/.ziyan_go_home"
  FRONT=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  echo "HOME try=$i front=$FRONT"
  echo "$FRONT" | grep -qi springboard && break
done
for i in 1 2 3 4 5 6; do
  echo 1 >"$VAR/.ziyan_force_recap"
  echo "nonce=p1_color_$i" >"$VAR/.ziyan_frame_req"
  sleep 1
  FRONT=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  SHM=$(tr -d '\r\n' <"$VAR/.ziyan_shm_front_bid" 2>/dev/null)
  echo "ALIGN try=$i front=$FRONT shm=$SHM"
  echo "$FRONT/$SHM" | grep -qi 'springboard/springboard' && break
done

if [ "$SCRIPT" = ios8p.lua ]; then
  X=2011; Y=283
  MAIN=0xfdfdef
  OFF='1|2|0xfeffff,2|3|0xffffec,2|7|0xfdfee1'
  X2=2013; Y2=290
else
  X=1010; Y=294
  MAIN=0x8d2619
  OFF='0|2|0x8b2f20,0|4|0x7b2117,0|6|0x7b231a'
  X2=1010; Y2=300
fi

cat >"$MEDIA/_p1_color_probe.lua" <<LUA
function main()
  init(1)
  local out = "$MEDIA/_p1_color_probe_out.txt"
  local function w(s)
    local f = io.open(out, "a")
    if f then f:write(tostring(s) .. "\\n"); f:close() end
  end
  local x, y = $X, $Y
  local pts = {{0,0},{0,2},{0,4},{0,6},{1,2},{2,3},{2,7}}
  for _, p in ipairs(pts) do
    local c = -1
    if type(getColor) == "function" then c = tonumber(getColor(x + p[1], y + p[2])) or -1 end
    w(string.format("GET dx=%d dy=%d value=%d hex=%06x", p[1], p[2], c, c >= 0 and c or 0))
  end
  local fx, fy = -1, -1
  if type(findMultiColorInRegionFuzzy) == "function" then
    fx, fy = findMultiColorInRegionFuzzy($MAIN, "$OFF", 90, $X, $Y, $X2, $Y2)
  end
  w(string.format("FIND xy=%s,%s", tostring(fx), tostring(fy)))
  w("done")
end
LUA
chmod 666 "$MEDIA/_p1_color_probe.lua"
printf 'path=%s/_p1_color_probe.lua\nstop=0\n' "$MEDIA" >"$VAR/.ziyan_run_intent"
printf '%s/_p1_color_probe.lua\n' "$MEDIA" >"$VAR/.ziyan_embed_script"
echo "nonce=p1_color_$$" >"$VAR/.ziyan_embed_go"
chmod 666 "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_go" 2>/dev/null

for i in $(seq 1 60); do
  grep -q '^done$' "$MEDIA/_p1_color_probe_out.txt" 2>/dev/null && break
  sleep 0.25
done
echo "--- OUT ---"
cat "$MEDIA/_p1_color_probe_out.txt" 2>/dev/null || echo "NO_OUT"
echo "LAST_FIND=$(tr '\n' ' ' <"$VAR/.ziyan_last_find" 2>/dev/null)"
echo "CONTRACT=$(tr '\n' ' ' <"$VAR/.ziyan_find_contract" 2>/dev/null)"
if grep -q '^FIND xy=[0-9][0-9]*,[0-9][0-9]*$' "$MEDIA/_p1_color_probe_out.txt" 2>/dev/null; then
  echo "VERDICT=PASS"
else
  echo "VERDICT=FAIL"
fi
printf 'ts=1\n' >"$VAR/.ziyan_kill_scripts"
sleep 1
rm -f "$VAR/.ziyan_kill_scripts" "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" \
  "$VAR/.ziyan_embed_go" "$VAR/.ziyan_active" "$MEDIA/_p1_color_probe.lua"
EOS
}

case "$WANT" in
  all)
    run_one 53 192.168.31.53 rootless ios8p.lua
    run_one 101 192.168.31.101 rootful ios7.lua
    run_one 112 192.168.31.112 rootful ios7.lua
    run_one 166 192.168.31.166 rootful ios7.lua
    ;;
  53) run_one 53 192.168.31.53 rootless ios8p.lua ;;
  101) run_one 101 192.168.31.101 rootful ios7.lua ;;
  112) run_one 112 192.168.31.112 rootful ios7.lua ;;
  166) run_one 166 192.168.31.166 rootful ios7.lua ;;
  *) echo "usage: $0 [all|53|101|112|166]"; exit 2 ;;
esac

pass_n=0
fail_n=0
for f in "$OUT"/gate_*.txt; do
  [ -f "$f" ] || continue
  if grep -q '^VERDICT=PASS$' "$f"; then pass_n=$((pass_n + 1)); else fail_n=$((fail_n + 1)); fi
done
{
  echo "# P1/P2 desktop color-chain probe"
  echo "stamp=$STAMP want=$WANT"
  echo "PASS_HOSTS=$pass_n FAIL_HOSTS=$fail_n"
  [ "$fail_n" = 0 ] && echo "VERDICT=PASS" || echo "VERDICT=FAIL"
} | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
