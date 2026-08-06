#!/usr/bin/env bash
# Rootful gate: foreground ZiYan minimize contract + init(0/1/2) touch mapping.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS="${ZY_SSH_PASS:-alpine}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=12 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1)

ssh_r() {
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"
}

bash "$ROOT/tools/zy_pretest_clean_4phone.sh"

fail=0
for tag in 101 112 166; do
  ip="192.168.31.$tag"
  echo "======== RF CONTRACT .$tag ========"
  if ! ssh_r "$ip" "TAG=$tag bash -s" <<'REMOTE'
set -euo pipefail
V=/usr/lib/ziyan/var
R=/usr/lib/ziyan
M=/private/var/mobile/Media/ZiYan
mkdir -p "$V" "$M"

cat >"$M/_rf_min_contract.lua" <<'LUA'
function main()
  init(1)
  local f = io.open("/usr/lib/ziyan/var/.ziyan_rf_min_script", "w")
  if f then
    f:write("running\n")
    f:close()
  end
  for _ = 1, 80 do
    mSleep(100)
  end
end
LUA
chmod 644 "$M/_rf_min_contract.lua"

rm -f "$V/.ziyan_minimize_log" "$V/.ziyan_app_minimize_req" \
      "$V/.ziyan_rf_min_script" "$V/.ziyan_embed_ack"
echo com.ziyan.ziyan >"$V/.ziyan_open_app"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  front=$(cat "$V/.ziyan_front_bid" 2>/dev/null || true)
  [ "$front" = "com.ziyan.ziyan" ] && break
  if [ $((i % 3)) -eq 0 ]; then
    echo com.ziyan.ziyan >"$V/.ziyan_open_app"
  fi
  sleep 0.5
done
front_before=$(cat "$V/.ziyan_front_bid" 2>/dev/null || true)
if [ "$front_before" != "com.ziyan.ziyan" ]; then
  echo "MIN_FAIL front_before=$front_before"
  exit 11
fi

printf 'path=%s/_rf_min_contract.lua\nstop=0\n' "$M" >"$V/.ziyan_run_intent"
printf '%s/_rf_min_contract.lua\n' "$M" >"$V/.ziyan_embed_script"
echo 1 >"$V/.ziyan_embed_on"
echo "nonce=rf_min_${TAG}_$$" >"$V/.ziyan_embed_go"
chmod 666 "$V/.ziyan_run_intent" "$V/.ziyan_embed_script" \
  "$V/.ziyan_embed_on" "$V/.ziyan_embed_go"
sleep 4

for _ in 1 2 3 4 5 6 7 8; do
  front_now=$(cat "$V/.ziyan_front_bid" 2>/dev/null || true)
  app_now=$(ps -A -o state=,command= 2>/dev/null |
    grep '/Applications/ZiYan.app/ZiYan' | grep -v grep |
    grep -vc '^[[:space:]]*Z' || true)
  [ "$front_now" != "com.ziyan.ziyan" ] && [ "$app_now" -eq 0 ] && break
  sleep 0.5
done
front_after=$(cat "$V/.ziyan_front_bid" 2>/dev/null || true)
app_n=$(ps -A -o state=,command= 2>/dev/null |
  grep '/Applications/ZiYan.app/ZiYan' | grep -v grep |
  grep -vc '^[[:space:]]*Z' || true)
embed=0
[ -f "$V/.ziyan_lua_embedded" ] && embed=1
min_hit=0
grep -q 'start_contract minimize front=com.ziyan.ziyan' \
  "$V/.ziyan_minimize_log" 2>/dev/null && min_hit=1
script_hit=0
[ -f "$V/.ziyan_rf_min_script" ] && script_hit=1
echo "MIN front_before=$front_before front_after=$front_after app_n=$app_n embed=$embed min_hit=$min_hit script_hit=$script_hit"
tail -n 12 "$V/.ziyan_minimize_log" 2>/dev/null | sed 's/^/MIN_LOG /'
if [ "$front_after" = "com.ziyan.ziyan" ] ||
   [ "$app_n" -ne 0 ] || [ "$embed" -ne 1 ] ||
   [ "$min_hit" -ne 1 ] || [ "$script_hit" -ne 1 ]; then
  exit 12
fi

printf 'stop=1\n' >"$V/.ziyan_run_intent"
echo 1 >"$V/.ziyan_kill_scripts"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
  [ ! -f "$V/.ziyan_lua_embedded" ] && break
  sleep 0.5
done
[ ! -f "$V/.ziyan_lua_embedded" ]
rm -f "$V/.ziyan_kill_scripts" "$V/.ziyan_rf_min_script"
echo 1 >"$V/.ziyan_go_home"
sleep 1
rm -f "$V/.ziyan_go_home"

run_orient() {
  o="$1"
  x="$2"
  y="$3"
  script="$M/_rf_orient_${o}.lua"
  cat >"$script" <<LUA
function main()
  init($o)
  mSleep(100)
end
LUA
  rm -f "$V/.ziyan_tap_proof" "$V/.ziyan_touch_log" \
        "$V/.ziyan_touch_req" "$V/.ziyan_touch_rep" \
        "$V/.ziyan_app_alive" "$V/.ziyan_prefer_app_touch"
  "$R/bin/lua5.3" "$R/lib/lua/ziyan_run.lua" "$script" \
    >"/tmp/ziyan_rf_orient_${o}.log" 2>&1
  for n in 1 2 3 4 5; do
    nonce="rf_o${o}_${TAG}_${n}_$$"
    rm -f "$V/.ziyan_touch_rep"
    printf 'tap\n1\n%s\n%s\n60\n%s\n' "$x" "$y" "$nonce" \
      >"$V/.ziyan_touch_req"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      rep=$(head -n 1 "$V/.ziyan_touch_rep" 2>/dev/null || true)
      [ "$rep" = "$nonce" ] && break
      sleep 0.05
    done
    [ "${rep:-}" = "$nonce" ]
  done
  proof=$(tail -n 1 "$V/.ziyan_touch_log" 2>/dev/null || true)
  orient=$(head -n 1 "$V/.ziyan_orient" 2>/dev/null || true)
  front=$(cat "$V/.ziyan_front_bid" 2>/dev/null || true)
  echo "ORIENT o=$o input=$x,$y state=$orient front=$front proof=$proof"
  echo "$proof" | grep -q "logic=${x},${y} "
  echo "$proof" | grep -Eq 'hid=0\.501,0\.05[01]'
  echo "$proof" | grep -q "orient=$o "
  [ "$orient" = "$o" ]
  [ "$front" != "com.ziyan.ziyan" ]
}

# All three logical points are the same physical point: portrait top-center.
run_orient 0 320 57
run_orient 1 57 320
run_orient 2 1079 320

rm -f "$M/_rf_min_contract.lua" "$M"/_rf_orient_*.lua
version=$(dpkg -s com.ziyan.ziyan 2>/dev/null |
  sed -n 's/^Version: //p' | head -n 1)
echo "DEVICE_PASS tag=$TAG version=$version"
REMOTE
  then
    fail=$((fail + 1))
    echo "DEVICE_FAIL tag=$tag"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "RF_MIN_ORIENT_GATE=FAIL count=$fail"
  exit 1
fi
echo "RF_MIN_ORIENT_GATE=PASS"
