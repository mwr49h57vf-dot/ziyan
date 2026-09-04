#!/usr/bin/env bash
# Device-only foreground diagnostic. The embedded Lua body deliberately does
# not call tap/touchDown/touchMove/touchUp so it isolates init(1) from input.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-192.168.31.112}"
TAG="${2:-112}"
VAR="/usr/lib/ziyan/var"
MEDIA="/private/var/mobile/Media/ZiYan"
TARGET_BID="com.xztl.ios"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/INIT_FOREGROUND_PROBE_${TAG}_${STAMP}"
mkdir -p "$OUT"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=15
  -o BatchMode=yes
  -o ServerAliveInterval=20
  -o ServerAliveCountMax=6
)

ssh "${SSH_OPTS[@]}" "root@$HOST" \
  "VAR='$VAR' MEDIA='$MEDIA' TARGET_BID='$TARGET_BID' bash -s" <<'REMOTE' \
  | tee "$OUT/device_probe.txt"
set +e
mkdir -p "$VAR" "$MEDIA"
PROBE="$MEDIA/_zy_init_only_probe.lua"
OUTFILE="$MEDIA/_zy_init_only_probe.out"

printf 'ts=1\n' >"$VAR/.ziyan_kill_scripts"
sleep 1
rm -f "$VAR/.ziyan_kill_scripts" "$VAR/.ziyan_run_intent" \
  "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_go" \
  "$VAR/.ziyan_active" "$VAR/.ziyan_embed_alive" \
  "$VAR/.ziyan_lua_embedded" "$VAR/.zy_init_only_heartbeat" "$OUTFILE"

cat >"$PROBE" <<'LUA'
function main()
  local out = "/private/var/mobile/Media/ZiYan/_zy_init_only_probe.out"
  local hb = "/usr/lib/ziyan/var/.zy_init_only_heartbeat"
  local function write(path, body)
    local f = io.open(path, "w")
    if f then f:write(body); f:close() end
  end
  write(out, "stage=before_init\n")
  local ok, err = pcall(init, 1)
  write(out, string.format("stage=after_init ok=%s err=%s\n", tostring(ok), tostring(err)))
  for n = 1, 48 do
    write(hb, string.format("n=%d\n", n))
    local f = io.open(out, "a")
    if f then f:write(string.format("heartbeat=%d\n", n)); f:close() end
    mSleep(250)
  end
  write(out, "stage=done\n")
end
LUA
chmod 666 "$PROBE"

for i in 1 2 3 4 5 6; do
  echo 1 >"$VAR/.ziyan_go_home"
  sleep 0.7
  rm -f "$VAR/.ziyan_go_home"
  front=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  echo "HOME i=$i front=$front"
  echo "$front" | grep -qi springboard && break
done

printf '%s\n' "$TARGET_BID" >"$VAR/.ziyan_open_app"
echo "OPEN requested=$TARGET_BID"
matched=0
for i in $(seq 1 32); do
  front=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  gate=$(tr '\n' '|' <"$VAR/.ziyan_open_app_gate" 2>/dev/null)
  echo "OPEN_SAMPLE i=$i front=$front gate=$gate"
  if [ "$front" = "$TARGET_BID" ]; then
    matched=1
    break
  fi
  sleep 0.25
done

if [ "$matched" != 1 ]; then
  echo "VERDICT=FAIL reason=target_never_foreground"
  exit 0
fi

printf 'path=%s\nstop=0\n' "$PROBE" >"$VAR/.ziyan_run_intent"
printf '%s\n' "$PROBE" >"$VAR/.ziyan_embed_script"
printf 'nonce=init_only_%s\n' "$$" >"$VAR/.ziyan_embed_go"
chmod 666 "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" \
  "$VAR/.ziyan_embed_go" 2>/dev/null

for i in $(seq 0 55); do
  front=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  orient=$(tr '\n' ',' <"$VAR/.ziyan_orient" 2>/dev/null)
  initargs=$(tr '\n' ',' <"$VAR/.ziyan_init_args" 2>/dev/null)
  embed=$(tr '\n' '|' <"$VAR/.ziyan_embed_alive" 2>/dev/null)
  hb=$(tr '\n' '|' <"$VAR/.zy_init_only_heartbeat" 2>/dev/null)
  appfg=$(tr '\n' '|' <"$VAR/.ziyan_app_fg" 2>/dev/null)
  probe=$(tr '\n' '|' <"$OUTFILE" 2>/dev/null | tail -c 180)
  printf 'SAMPLE i=%d front=%s orient=%s init_args=%s embed=%s heartbeat=%s app_fg=%s probe=%s\n' \
    "$i" "$front" "$orient" "$initargs" "$embed" "$hb" "$appfg" "$probe"
  sleep 0.25
done

echo "--- INIT_ONLY_OUTPUT ---"
cat "$OUTFILE" 2>/dev/null || true
final_front=$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
if grep -q '^stage=done$' "$OUTFILE" 2>/dev/null && [ "$final_front" = "$TARGET_BID" ]; then
  echo "VERDICT=PASS"
else
  echo "VERDICT=FAIL reason=foreground_or_script_lost final_front=$final_front"
fi

printf 'ts=1\n' >"$VAR/.ziyan_kill_scripts"
sleep 1
rm -f "$VAR/.ziyan_kill_scripts" "$VAR/.ziyan_run_intent" \
  "$VAR/.ziyan_embed_script" "$VAR/.ziyan_embed_go" \
  "$VAR/.ziyan_active" "$PROBE" "$VAR/.zy_init_only_heartbeat"
REMOTE

printf 'OUT=%s\n' "$OUT"
