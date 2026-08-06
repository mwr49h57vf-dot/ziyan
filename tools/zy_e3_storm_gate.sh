#!/usr/bin/env bash
# 刀 E3：force_recap / toast_bump 风暴门禁（默认双机 .101+.53）
# 验收：稳态找色 HOT_FORCE≤2 且 TOAST_BUMP=0；idle force mtime=0
# 用法: bash tools/zy_e3_storm_gate.sh [101 53]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
if [ "$#" -eq 0 ]; then HOSTS=(101 53); else HOSTS=("$@"); fi
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="${ROOT}/tmp_shots/E3_STORM_${STAMP}"
mkdir -p "$OUT"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12
          -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }

PASS_N=0
FAIL_N=0
for H in "${HOSTS[@]}"; do
  IP="192.168.31.$H"
  SCHEME=rootful
  [ "$H" = "53" ] && SCHEME=rootless
  echo "==== E3 .$H ===="
  ssh_r "$IP" "SCHEME=$SCHEME bash -s" <<'R' | tee "$OUT/gate_${H}.txt"
set +e
if [ "$SCHEME" = rootless ]; then
  V=/var/jb/usr/lib/ziyan/var; B=/var/jb/usr/lib/ziyan/bin
else
  V=/usr/lib/ziyan/var; B=/usr/lib/ziyan/bin
fi
MEDIA=/private/var/mobile/Media/ZiYan
mkdir -p "$MEDIA" "$V"
VER=$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)
echo "VER=$VER"
echo 1 >"$V/.ziyan_no_auto_keep"; chmod 666 "$V/.ziyan_no_auto_keep" 2>/dev/null || true
: >"$V/.ziyan_kill_scripts"; printf 'ts=1\n' >"$V/.ziyan_kill_scripts"
chmod 666 "$V/.ziyan_kill_scripts" 2>/dev/null || true
sleep 0.8
rm -f "$V/.ziyan_embed_off" "$V/.ziyan_force_recap" "$V/.ziyan_toast_bump" \
  "$V/.ziyan_embed_go" "$V/.ziyan_lua_embedded" "$V/.ziyan_active"
launchctl kickstart -k system/com.ziyan.framecap 2>/dev/null || true
sleep 1

# idle 6s force mtime
c_force=0
f0=$(stat -f %m "$V/.ziyan_force_recap" 2>/dev/null || echo 0)
for i in 1 2 3 4 5 6; do
  sleep 1
  f1=$(stat -f %m "$V/.ziyan_force_recap" 2>/dev/null || echo 0)
  if [ "$f1" != "$f0" ] && [ "$f1" != 0 ]; then c_force=$((c_force+1)); f0=$f1; fi
done
echo "IDLE_FORCE_CHG=$c_force"

cat >"$MEDIA/_e3_storm.lua" <<'LUA'
for i = 1, 50 do
  if type(findMultiColorInRegionFuzzy) == "function" then
    findMultiColorInRegionFuzzy(0xFFFFFF, "", 90, 0, 0, 40, 40)
  end
  if type(mSleep) == "function" then mSleep(40)
  elseif type(ziyan_embed_msleep) == "function" then ziyan_embed_msleep(40) end
end
LUA
chmod 666 "$MEDIA/_e3_storm.lua"
rm -f "$V/.ziyan_user_stopped" "$V/.ziyan_stop" "$V/.ziyan_force_recap" "$V/.ziyan_toast_bump"
printf 'path=%s/_e3_storm.lua\nstop=0\n' "$MEDIA" >"$V/.ziyan_run_intent"
printf '%s/_e3_storm.lua\n' "$MEDIA" >"$V/.ziyan_embed_script"
echo "nonce=e3_$RANDOM" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_embed_go" "$V/.ziyan_embed_script" "$V/.ziyan_run_intent"

hf=0; ht=0
end=$(( $(date +%s) + 14 ))
while [ "$(date +%s)" -lt "$end" ]; do
  if [ -f "$V/.ziyan_force_recap" ]; then hf=$((hf+1)); rm -f "$V/.ziyan_force_recap"; fi
  if [ -f "$V/.ziyan_toast_bump" ]; then ht=$((ht+1)); rm -f "$V/.ziyan_toast_bump"; fi
  sleep 0.12
done
printf 'ts=1\n' >"$V/.ziyan_kill_scripts"; chmod 666 "$V/.ziyan_kill_scripts" 2>/dev/null || true
sleep 1
echo "HOT_FORCE_HITS=$hf TOAST_BUMP_HITS=$ht"
# path_stats embed still ok
STATS=$(tr '\n' ' ' <"$V/.ziyan_path_stats" 2>/dev/null)
CR=$(echo "$STATS" | sed -n 's/.*via_color_req_find=\([0-9][0-9]*\).*/\1/p')
[ -z "$CR" ] && CR=-1
echo "STATS=$STATS"

OK=1
echo "$VER" | grep -qE '195' || { echo "FAIL ver_not_195"; OK=0; }
[ "$c_force" = "0" ] || { echo "FAIL idle_force=$c_force"; OK=0; }
# 稳态找色：允许启动偶发 1～2 次 force；禁止 toast_bump
[ "$hf" -le 2 ] 2>/dev/null || { echo "FAIL hot_force=$hf"; OK=0; }
[ "$ht" = "0" ] || { echo "FAIL toast_bump=$ht"; OK=0; }
[ "$CR" = "0" ] || [ "$CR" = "-1" ] || { echo "FAIL color_req_find=$CR"; OK=0; }
if [ "$OK" = 1 ]; then echo "VERDICT=PASS"; else echo "VERDICT=FAIL"; fi
R
  if grep -q 'VERDICT=PASS' "$OUT/gate_${H}.txt" 2>/dev/null; then
    PASS_N=$((PASS_N + 1))
  else
    FAIL_N=$((FAIL_N + 1))
  fi
done

{
  echo "# E3 storm gate"
  echo "stamp=$STAMP hosts=${HOSTS[*]}"
  echo "PASS_N=$PASS_N FAIL_N=$FAIL_N"
  if [ "$FAIL_N" -eq 0 ] && [ "$PASS_N" -gt 0 ]; then echo "VERDICT=PASS"; else echo "VERDICT=FAIL"; fi
} | tee "$OUT/VERDICT.md"
echo "OUT=$OUT"
[ "$FAIL_N" -eq 0 ] && [ "$PASS_N" -gt 0 ]
