#!/usr/bin/env bash
# Execute one AI-generated capability suite on one real device.
# Shell only stages, starts, observes, and cleans the run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:?usage: $0 <101|112|166|53|61> <chat|rules|decision|non_visual>}"
CAP="${2:?usage: $0 <101|112|166|53|61> <chat|rules|decision|non_visual>}"
EXPECTED_PACKAGE_VERSION="${ZY_EXPECTED_PACKAGE_VERSION:-}"
EXPECTED_PACKAGE_SHA="${ZY_EXPECTED_PACKAGE_SHA:-}"
TARGET_BID="${ZY_CAPABILITY_BID:-com.ziyan.ziyan}"
PACKAGE_FILE="${ZY_CAPABILITY_PACKAGE_FILE:-}"
case "$TAG" in
  101|112|166) HOST="192.168.31.$TAG"; USER=root; SCHEME=rootful; VAR=/usr/lib/ziyan/var ;;
  53) HOST=192.168.31.53; USER=root; SCHEME=rootless; VAR=/var/jb/usr/lib/ziyan/var ;;
  61) HOST=192.168.31.61; USER=mobile; SCHEME=rootless; VAR=/var/jb/usr/lib/ziyan/var ;;
  *) echo "invalid device .$TAG" >&2; exit 2 ;;
esac
case "$CAP" in
  chat|rules|decision|non_visual) ;;
  *) echo "invalid capability $CAP" >&2; exit 2 ;;
esac
python3 "$ROOT/tools/ziyan_capability_sequence.py" check --capability "$CAP" --device ".$TAG"

OUT="$ROOT/tmp_shots/CAPABILITY_${CAP}_DEVICE_${TAG}_$(date '+%Y%m%d_%H%M%S')_$$"
mkdir -p "$OUT"
PASS="${ZY_SSH_PASS:-alpine}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15
          -o ServerAliveInterval=10 -o ServerAliveCountMax=6)
if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$USER@$HOST" true >/dev/null 2>&1; then
  SSH=(ssh "${SSH_OPTS[@]}" "$USER@$HOST")
  SCP=(scp "${SSH_OPTS[@]}")
else
  SSH=(sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USER@$HOST")
  SCP=(sshpass -p "$PASS" scp "${SSH_OPTS[@]}")
fi

echo "[capability] mandatory four-device cleanup before .$TAG/$CAP"
bash "$ROOT/tools/zy_pretest_clean_4phone.sh" >"$OUT/pretest.txt" 2>&1

BOOT="$OUT/bootstrap_${CAP}.lua"
cat >"$BOOT" <<LUA
-- AI-GENERATED bootstrap: the capability business script is generated on-device.
local V = "$VAR"
local CAP = "$CAP"
local OUT = V .. "/.ziyan_capability_result"
local function write(s)
  local f = io.open(OUT, "w")
  if f then f:write(s); f:close() end
end
function main()
  local ok, err = xpcall(function()
    require("modules")
    local goal = CAP == "chat" and "聊天模块四机真实验证" or
      (CAP == "rules" and "游戏规则状态机计分胜负" or
      (CAP == "decision" and "自动决策追踪重试暂停恢复" or "非视觉剪贴板硬件键应用生命周期"))
    local rep = Zy.AI.pipeline(goal, {
      bid = "$TARGET_BID", design_w = 1136, design_h = 640,
      real_device = true, skip_repair = true, max_loop = 1,
    })
    local existing = ""
    local f = io.open(OUT, "r")
    if f then existing = f:read("*a") or ""; f:close() end
    if existing:find("result_ready=1", 1, true) then
      write(string.format(
        "pipeline_ok=%s\npath=%s\n",
        tostring(rep and rep.ok), tostring(rep and rep.path)
      ) .. existing)
    else
      local key = "capability_" .. CAP
      local module_ok = Zy.Script.get(key) == true
      write(string.format(
        "capability=%s\npipeline_ok=%s\nmodule_ok=%s\nreal_device=true\nbootstrap_error=generated_result_missing\nreason=%s\n",
        CAP, tostring(rep and rep.ok), tostring(module_ok),
        tostring(rep and rep.detail and (rep.detail.reason or rep.detail.err or rep.detail.phase) or "")
      ))
    end
  end, debug.traceback)
  if not ok then
    write(string.format("capability=%s\npipeline_ok=false\nmodule_ok=false\nreal_device=true\nbootstrap_error=%s\n",
      CAP, tostring(err):gsub("\n", "\\n")))
  end
end
return main
LUA

MEDIA=/private/var/mobile/Media/ZiYan
"${SCP[@]}" "$BOOT" "$USER@$HOST:$MEDIA/capability_bootstrap_${CAP}.lua" >"$OUT/scp.txt" 2>&1
"${SSH[@]}" "SCHEME='$SCHEME' VAR='$VAR' MEDIA='$MEDIA' CAP='$CAP' TARGET_BID='$TARGET_BID' PACKAGE_FILE='$PACKAGE_FILE' EXPECTED_PACKAGE_VERSION='$EXPECTED_PACKAGE_VERSION' EXPECTED_PACKAGE_SHA='$EXPECTED_PACKAGE_SHA' bash -s" >"$OUT/device.txt" 2>&1 <<'REMOTE'
set -e
SCRIPT="$MEDIA/capability_bootstrap_${CAP}.lua"
rm -f "$VAR/.ziyan_capability_result" "$VAR/.ziyan_embed_ack" "$VAR/.ziyan_run_ack" \
      "$VAR/.ziyan_ready_ack" "$VAR/.ziyan_lua_embedded" "$VAR/.ziyan_embed_alive" \
      "$VAR/.ziyan_active" "$VAR/.ziyan_user_stopped" "$VAR/.ziyan_kill_scripts" \
      "$VAR/.ziyan_expected_package_version" "$VAR/.ziyan_expected_package_sha" \
      "$VAR/.ziyan_capability_context"
printf '%s\n' "$EXPECTED_PACKAGE_VERSION" >"$VAR/.ziyan_expected_package_version"
printf '%s\n' "$EXPECTED_PACKAGE_SHA" >"$VAR/.ziyan_expected_package_sha"
printf 'path=%s\nstop=0\n' "$SCRIPT" >"$VAR/.ziyan_run_intent"
printf '%s\n' "$SCRIPT" >"$VAR/.ziyan_embed_script"
date +%s >"$VAR/.ziyan_project_active"
printf 'nonce=cap_%s_%s\nrequest_id=cap_%s_%s\nsession_id=cap_%s_%s\n' \
  "$CAP" "$$" "$CAP" "$$" "$CAP" "$$" >"$VAR/.ziyan_embed_go"
cp "$VAR/.ziyan_embed_go" "$VAR/.ziyan_capability_context"
echo 1 >"$VAR/.ziyan_embed_on"
chmod 666 "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" "$VAR/.ziyan_project_active" \
  "$VAR/.ziyan_embed_go" "$VAR/.ziyan_capability_context" "$VAR/.ziyan_embed_on" 2>/dev/null || true
for i in $(seq 1 180); do
  [ -s "$VAR/.ziyan_capability_result" ] &&
    grep -q '^pipeline_ok=' "$VAR/.ziyan_capability_result" &&
    { echo RESULT_READY=1 wait=$i; break; }
  sleep 0.5
done
cat "$VAR/.ziyan_capability_result" 2>/dev/null || true
printf 'front=%s\n' "$(tr -d '\r\n' <"$VAR/.ziyan_front_bid" 2>/dev/null || true)"
printf 'target_bid=%s\n' "$TARGET_BID"
printf 'package_version=%s\n' "$(dpkg-query -W -f='${Version}' com.ziyan.ziyan 2>/dev/null || true)"
if [ -n "$PACKAGE_FILE" ] && [ -f "$PACKAGE_FILE" ]; then
  ACTUAL_PACKAGE_FILE="$PACKAGE_FILE"
else
  ACTUAL_PACKAGE_FILE="$(ls -t "$MEDIA"/ziyan_deploy_*.deb 2>/dev/null | head -1 || true)"
fi
printf 'package_file=%s\n' "$ACTUAL_PACKAGE_FILE"
if [ -n "$ACTUAL_PACKAGE_FILE" ] && [ -f "$ACTUAL_PACKAGE_FILE" ]; then
  printf 'package_sha=%s\n' "$(sha256sum "$ACTUAL_PACKAGE_FILE" 2>/dev/null | cut -d ' ' -f 1 || shasum -a 256 "$ACTUAL_PACKAGE_FILE" 2>/dev/null | cut -d ' ' -f 1)"
else
  printf 'package_sha=\n'
fi
printf 'fc_n=%s\n' "$(ps -A -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep || true)"
printf 'active=%s\n' "$([ -e "$VAR/.ziyan_active" ] && echo 1 || echo 0)"
printf 'embed=%s\n' "$([ -e "$VAR/.ziyan_embed_alive" ] || [ -e "$VAR/.ziyan_lua_embedded" ] && echo 1 || echo 0)"
printf 'stop=1\n' >"$VAR/.ziyan_kill_scripts"
sleep 2
rm -f "$VAR/.ziyan_kill_scripts" "$VAR/.ziyan_run_intent" "$VAR/.ziyan_embed_script" \
  "$VAR/.ziyan_embed_go" "$VAR/.ziyan_project_active" "$VAR/.ziyan_active" \
  "$VAR/.ziyan_lua_embedded" "$VAR/.ziyan_embed_alive" "$VAR/.ziyan_capability_context" \
  "$MEDIA/capability_bootstrap_${CAP}.lua"
printf 'cleanup_active=%s\n' "$([ -e "$VAR/.ziyan_active" ] && echo 1 || echo 0)"
printf 'cleanup_embed=%s\n' "$([ -e "$VAR/.ziyan_embed_alive" ] || [ -e "$VAR/.ziyan_lua_embedded" ] && echo 1 || echo 0)"
printf 'cleanup_active=%s\n' "$([ -e "$VAR/.ziyan_active" ] && echo 1 || echo 0)"
REMOTE

cat "$OUT/device.txt"
kv() { awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$OUT/device.txt"; }
RESULT_READY="$(kv result_ready)"
MODULE_OK="$(kv module_ok)"
PIPELINE_OK="$(kv pipeline_ok)"
REAL_DEVICE="$(kv real_device)"
EVIDENCE_CAP="$(kv capability)"
RESULT_NONCE="$(kv nonce)"
RESULT_SESSION="$(kv session_id)"
FRONT="$(kv front)"
TARGET="$(kv target_bid)"
PACKAGE_VERSION="$(kv package_version)"
PACKAGE_SHA="$(kv package_sha)"
FC_N="$(kv fc_n)"
ACTIVE="$(kv active)"
EMBED="$(kv embed)"
CLEANUP_ACTIVE="$(kv cleanup_active)"
CLEANUP_EMBED="$(kv cleanup_embed)"
EXPECTED_NONCE="cap_${CAP}_"
EXPECTED_SESSION="cap_${CAP}_"
VERSION_OK="$([ -n "$EXPECTED_PACKAGE_VERSION" ] && [ "$PACKAGE_VERSION" = "$EXPECTED_PACKAGE_VERSION" ] && echo 1 || echo 0)"
SHA_OK="$([ -n "$EXPECTED_PACKAGE_SHA" ] && [ "$PACKAGE_SHA" = "$EXPECTED_PACKAGE_SHA" ] && echo 1 || echo 0)"
NONCE_OK="$([ "$RESULT_NONCE" = "$EXPECTED_NONCE" ] || [[ "$RESULT_NONCE" == "$EXPECTED_NONCE"* ]]; echo $?)"
SESSION_OK="$([ "$RESULT_SESSION" = "$EXPECTED_SESSION" ] || [[ "$RESULT_SESSION" == "$EXPECTED_SESSION"* ]]; echo $?)"
if [ "$RESULT_READY" = "1" ] &&
   [ "$MODULE_OK" = "true" ] &&
   [ "$PIPELINE_OK" = "true" ] &&
   [ "$REAL_DEVICE" = "true" ] &&
   [ "$EVIDENCE_CAP" = "$CAP" ] &&
   [ "$NONCE_OK" = "0" ] &&
   [ "$SESSION_OK" = "0" ] &&
   [ "$FRONT" = "$TARGET" ] &&
   [ "$TARGET" = "$TARGET_BID" ] &&
   [ "$VERSION_OK" = "1" ] &&
   [ "$SHA_OK" = "1" ] &&
   [ "$FC_N" = "1" ] &&
   [ "$CLEANUP_ACTIVE" = "0" ] &&
   [ "$CLEANUP_EMBED" = "0" ]; then
  VERDICT=DEVICE_PASS
else
  VERDICT=DEVICE_INCONCLUSIVE
fi
{
  echo "# AI-generated capability gate"
  echo "device=.$TAG scheme=$SCHEME capability=$CAP"
  echo "verdict=$VERDICT"
  echo "generator=Zy.AI.pipeline (on-device) -> generated script -> Zy.AI.test"
  echo "local_simulation_pass=false"
  echo "required_package_version=$EXPECTED_PACKAGE_VERSION"
  echo "required_package_sha=$EXPECTED_PACKAGE_SHA"
  echo "evidence_session=$RESULT_SESSION"
  echo "evidence_nonce=$RESULT_NONCE"
  echo "front=$FRONT target=$TARGET fc_n=$FC_N active=$ACTIVE embed=$EMBED cleanup_active=$CLEANUP_ACTIVE cleanup_embed=$CLEANUP_EMBED"
  echo "evidence=$OUT/device.txt"
} | tee "$OUT/VERDICT.md"
python3 "$ROOT/tools/ziyan_capability_sequence.py" record \
  --capability "$CAP" --device ".$TAG" --verdict "$VERDICT" \
  --evidence "$OUT/VERDICT.md" --package-version "$PACKAGE_VERSION" \
  --package-sha256 "$PACKAGE_SHA" --fixture "$TARGET_BID" \
  --blocked-reason "$([ "$VERDICT" = DEVICE_PASS ] && printf '' || printf '%s' 'capability_gate_incomplete')"
rm -f "$BOOT"
echo "OUT=$OUT"
[ "$VERDICT" = DEVICE_PASS ]
