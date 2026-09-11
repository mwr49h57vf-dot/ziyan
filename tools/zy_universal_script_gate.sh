#!/usr/bin/env bash
# 通用性验收门禁：同一份业务脚本（逐字节相同）在矩阵内所有真机上，
# 从规范冷态出发、无人干预，必须都能自己达成目标（进入目标 App）。
#
# 为什么需要它（2026-09-11 教训）：
#   ios7.lua 的进游步骤写死桌面图标坐标 (1010,294)。.101/.112/.166 桌面是
#   「效率文件夹 + AppStore + 设置」3 格，正好命中；.61 是 iOS 15，首页多了
#   两个小组件 + Safari 共 6 格，同一坐标落在壁纸上，脚本永远进不了游戏。
#   这类缺陷用「单机跑通」永远发现不了，必须靠同一脚本跨机型/跨 iOS 版本比对。
#
# 用法：bash tools/zy_universal_script_gate.sh <script.lua> <target-bid> [devices...]
#   默认设备：101 112 166 53 61
#   ZY_UNIV_TIMEOUT=120  每机进游超时秒
#   ZY_UNIV_STAGGER=8    机间错峰秒（并行会撞设备 sshd 限流，2026-09-11 实测）
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SCRIPT_ARG="${1:?usage: $0 <script.lua> <target-bid> [devices...]}"
BID="${2:?usage: $0 <script.lua> <target-bid> [devices...]}"
shift 2
HOSTS=("$@")
[ "${#HOSTS[@]}" -eq 0 ] && HOSTS=(101 112 166 53 61)

TIMEOUT="${ZY_UNIV_TIMEOUT:-120}"
STAGGER="${ZY_UNIV_STAGGER:-8}"

[ -f "$SCRIPT_ARG" ] || { echo "REFUSE script not found: $SCRIPT_ARG" >&2; exit 2; }
case "$BID" in
  *.*) ;;
  *) echo "REFUSE invalid target bid: $BID" >&2; exit 2 ;;
esac

SCRIPT_ABS="$(cd "$(dirname "$SCRIPT_ARG")" && pwd)/$(basename "$SCRIPT_ARG")"
SCRIPT_SHA="$(shasum -a 256 "$SCRIPT_ABS" | awk '{print $1}')"
SCRIPT_SIZE="$(wc -c < "$SCRIPT_ABS" | tr -d ' ')"
SCRIPT_NAME="$(basename "$SCRIPT_ABS")"

STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/UNIVERSAL_${STAMP}"
mkdir -p "$OUT/per_device" "$OUT/payload"
cp "$SCRIPT_ABS" "$OUT/payload/$SCRIPT_NAME"

{
  echo "gate=universal_script"
  echo "started=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "script=$SCRIPT_ABS"
  echo "script_sha256=$SCRIPT_SHA"
  echo "script_bytes=$SCRIPT_SIZE"
  echo "target_bid=$BID"
  echo "devices=${HOSTS[*]}"
  echo "timeout_sec=$TIMEOUT"
  echo "# 同一份脚本字节必须发到每一台；门禁拒绝 per-device 变体。"
} > "$OUT/meta.txt"

echo "OUT=$OUT"
echo "SCRIPT=$SCRIPT_NAME sha=${SCRIPT_SHA:0:16} target=$BID devices=${HOSTS[*]} timeout=${TIMEOUT}s"

# iOS 13 上 `sysctl -n hw.model` 返回的是板号（D10AP/D101AP…），iOS 14+ 才回
# ProductType（iPhone9,1…）。两套都要认，否则机型列全是 unknown，矩阵覆盖无从谈起。
model_name() {
  case "$1" in
    iPhone9,1|iPhone9,3|D10AP|D101AP) echo "iPhone7" ;;
    iPhone9,2|iPhone9,4|D11AP|D111AP) echo "iPhone7Plus" ;;
    iPhone10,1|iPhone10,4|D20AP|D201AP) echo "iPhone8" ;;
    iPhone10,2|iPhone10,5|D21AP|D211AP) echo "iPhone8Plus" ;;
    *) echo "unknown($1)" ;;
  esac
}

ssh_for() {
  local user="$1" ip="$2"; shift 2
  if [ "$user" = mobile ]; then
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=12 "$user@$ip" "$@"
  elif ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=12 "$user@$ip" "true" >/dev/null 2>&1; then
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=12 "$user@$ip" "$@"
  else
    sshpass -p "${ZY_SSH_PASS:-alpine}" ssh \
      -o PubkeyAuthentication=no -o PreferredAuthentications=password \
      -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 "$user@$ip" "$@"
  fi
}

device_user() { [ "$1" = 61 ] && echo mobile || echo root; }

probe_device() {
  local tag="$1" user; user="$(device_user "$tag")"
  ssh_for "$user" "192.168.31.$tag" "PROBE_BID='$BID' bash -s" 2>/dev/null <<'EOS'
DQ=/usr/bin/dpkg-query; [ -x /var/jb/usr/bin/dpkg-query ] && DQ=/var/jb/usr/bin/dpkg-query
A=$($DQ -W -f='${Architecture}' com.ziyan.ziyan 2>/dev/null)
# 只按已装包 arch 判 scheme：rootful 机上残留的 /var/jb/usr/lib/ziyan 会骗过
# 目录存在性判断，把请求写进死目录，表现为「脚本没跑」而不是产品 FAIL。
if [ "$A" = "iphoneos-arm64" ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
S=/usr/sbin/sysctl; [ -x "$S" ] || S=/var/jb/usr/sbin/sysctl; [ -x "$S" ] || S=/usr/bin/sysctl; [ -x "$S" ] || S=sysctl
# `uname -m` 在 iOS 上给的是 ProductType（iPhone9,1…），五机实测都准；sysctl hw.model
# 在 iOS 13 给板号（D10AP…）、在 mobile 非交互环境还可能不在 PATH。两个都取，谁有算谁。
M=$(uname -m 2>/dev/null)
case "$M" in iPhone*|iPad*|iPod*) ;; *) M=$($S -n hw.model 2>/dev/null) ;; esac
echo "hw_model=$M"
echo "hw_model_sysctl=$($S -n hw.model 2>/dev/null)"
echo "ios=$(sw_vers -productVersion 2>/dev/null)"
echo "build=$(sw_vers -buildVersion 2>/dev/null)"
echo "scheme=$([ "$A" = iphoneos-arm64 ] && echo rootless || echo rootful)"
echo "pkg=$($DQ -W -f='${Version}' com.ziyan.ziyan 2>/dev/null)"
echo "var=$V"
echo "fc_n=$(ps -axo state=,args= | grep '[z]iyan_framecap serve' | grep -v '^[[:space:]]*Z' | wc -l | tr -dc '0-9')"
echo "script_procs=$(ps -axo args= | grep -c '[i]os7.lua')"
echo "front=$(cat $V/.ziyan_front_bid 2>/dev/null | tr -d '\r\n')"
echo "native_wh=$(tr '\n' 'x' < $V/.ziyan_native_wh 2>/dev/null)"
if grep -rlqa "$PROBE_BID" /var/containers/Bundle/Application/*/*.app/Info.plist 2>/dev/null; then
  echo "target_installed=1"
else
  echo "target_installed=0"
fi
EOS
}

clean_device() {
  local tag="$1" user; user="$(device_user "$tag")"
  ssh_for "$user" "192.168.31.$tag" 'bash -s' 2>/dev/null <<'EOS'
DQ=/usr/bin/dpkg-query; [ -x /var/jb/usr/bin/dpkg-query ] && DQ=/var/jb/usr/bin/dpkg-query
A=$($DQ -W -f='${Architecture}' com.ziyan.ziyan 2>/dev/null)
if [ "$A" = "iphoneos-arm64" ]; then V=/var/jb/usr/lib/ziyan/var; else V=/usr/lib/ziyan/var; fi
MEDIA=/var/mobile/Media/ZiYan
printf 'stop=1\n' > "$V/.ziyan_run_intent" 2>/dev/null
echo 1 > "$V/.ziyan_stop" 2>/dev/null
echo 1 > "$V/.ziyan_user_stopped" 2>/dev/null
printf 'com.xztl.ios\ncom.ljzbbadao.game\n' > "$V/.ziyan_close_app" 2>/dev/null
chmod 666 "$V/.ziyan_close_app" 2>/dev/null
sleep 6
rm -f "$V/.ziyan_close_app"
printf '1\n' > "$V/.ziyan_go_home"; chmod 666 "$V/.ziyan_go_home" 2>/dev/null
sleep 4; rm -f "$V/.ziyan_go_home"
rm -f "$V/.ziyan_active" "$V/.ziyan_keep_daemon" "$V/.ziyan_user_stopped" \
      "$V/.ziyan_stop" "$V/.ziyan_run_intent" "$V/.ziyan_embed_go" \
      "$V/.ziyan_embed_script" "$V/.ziyan_project_active" "$V/.ziyan_open_app" \
      "$MEDIA/.ziyan_open_app" "$V/.ziyan_menu_run_trig" "$V/.ziyan_app_run_trig" 2>/dev/null
FC=$(ps -axo state=,args= | grep '[z]iyan_framecap serve' | grep -v '^[[:space:]]*Z' | wc -l | tr -dc '0-9')
if [ "${FC:-0}" -eq 0 ]; then
  echo zydaemon > "$V/.ziyan_framecap_owner_mode" 2>/dev/null
  echo 1 > "$V/.ziyan_watchdog_framecap_need" 2>/dev/null
  chmod 666 "$V/.ziyan_framecap_owner_mode" "$V/.ziyan_watchdog_framecap_need" 2>/dev/null
  sleep 10
fi
echo "clean_front=$(cat $V/.ziyan_front_bid 2>/dev/null | tr -d '\r\n')"
echo "clean_fc_n=$(ps -axo state=,args= | grep '[z]iyan_framecap serve' | grep -v '^[[:space:]]*Z' | wc -l | tr -dc '0-9')"
EOS
}

push_device() {
  local tag="$1" user="$2" dst="$3"
  if [ "$user" = mobile ]; then
    scp -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 "$SCRIPT_ABS" "$user@192.168.31.$tag:$dst" >/dev/null 2>&1
  elif ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o ConnectTimeout=12 "root@192.168.31.$tag" "true" >/dev/null 2>&1; then
    scp -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 "$SCRIPT_ABS" "root@192.168.31.$tag:$dst" >/dev/null 2>&1
  else
    sshpass -p "${ZY_SSH_PASS:-alpine}" scp \
      -o PubkeyAuthentication=no -o PreferredAuthentications=password \
      -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 \
      "$SCRIPT_ABS" "root@192.168.31.$tag:$dst" >/dev/null 2>&1
  fi
}

run_device() {
  local tag="$1" model="$2" ios="$3" scheme="$4" pkg="$5"
  local user; user="$(device_user "$tag")"
  local dst="/var/mobile/Media/ZiYan/$SCRIPT_NAME"
  local dev="$OUT/per_device/$tag.txt"
  local t0 t1 elapsed goal hit streak sec front

  {
    echo "device=.$tag"
    echo "hw_model=$model"
    echo "ios=$ios"
    echo "scheme=$scheme"
    echo "package=$pkg"
    echo "script_sha256=$SCRIPT_SHA"
  } > "$dev"

  clean_device "$tag" >> "$dev" 2>&1

  if push_device "$tag" "$user" "$dst"; then
    echo "push_ok=1" >> "$dev"
  else
    echo "push_ok=0" >> "$dev"
    echo "device_verdict=TRANSPORT_BLOCKED" >> "$dev"
    echo ".$tag TRANSPORT_BLOCKED ($model iOS $ios)"
    return 1
  fi

  local remote_sha
  remote_sha="$(ssh_for "$user" "192.168.31.$tag" "shasum -a 256 '$dst' 2>/dev/null || sha256sum '$dst' 2>/dev/null" 2>/dev/null \
    | sed -n 's/^\([0-9a-fA-F]\{64\}\).*/\1/p' | head -1 | tr -d '\r')"
  echo "remote_sha256=$remote_sha" >> "$dev"
  if [ "$remote_sha" != "$SCRIPT_SHA" ]; then
    echo "device_verdict=SCRIPT_MISMATCH" >> "$dev"
    echo ".$tag SCRIPT_MISMATCH local=$SCRIPT_SHA remote=$remote_sha"
    return 1
  fi

  t0="$(date +%s)"
  ssh_for "$user" "192.168.31.$tag" \
    "V=\$( [ \"\$(/usr/bin/dpkg-query -W -f='\${Architecture}' com.ziyan.ziyan 2>/dev/null)\" = iphoneos-arm64 ] && echo /var/jb/usr/lib/ziyan/var || echo /usr/lib/ziyan/var ); printf '%s\n' '$dst' > \"\$V/.ziyan_menu_run_trig\"; chmod 666 \"\$V/.ziyan_menu_run_trig\"" \
    >/dev/null 2>&1

  goal=0; hit=0; streak=0
  for sec in $(seq 1 "$TIMEOUT"); do
    front="$(ssh_for "$user" "192.168.31.$tag" \
      "V=\$( [ \"\$(/usr/bin/dpkg-query -W -f='\${Architecture}' com.ziyan.ziyan 2>/dev/null)\" = iphoneos-arm64 ] && echo /var/jb/usr/lib/ziyan/var || echo /usr/lib/ziyan/var ); cat \$V/.ziyan_front_bid 2>/dev/null" 2>/dev/null | tr -d '\r\n')"
    if [ "$front" = "$BID" ]; then
      streak=$((streak+1))
      if [ "$streak" -ge 3 ]; then goal=1; hit="$sec"; break; fi
    else
      streak=0
    fi
    sleep 1
  done
  t1="$(date +%s)"; elapsed=$((t1-t0))
  echo "goal_reached=$goal" >> "$dev"
  echo "time_to_goal_sec=$hit" >> "$dev"
  echo "observed_sec=$elapsed" >> "$dev"

  ssh_for "$user" "192.168.31.$tag" "V=\$( [ \"\$(/usr/bin/dpkg-query -W -f='\${Architecture}' com.ziyan.ziyan 2>/dev/null)\" = iphoneos-arm64 ] && echo /var/jb/usr/lib/ziyan/var || echo /usr/lib/ziyan/var ); echo '--- toast ---'; tail -12 \$V/.ziyan_toast_hist 2>/dev/null; echo '--- find ---'; tail -6 \$V/.ziyan_find_shm_log 2>/dev/null" \
    >> "$dev" 2>&1

  clean_device "$tag" >> "$dev" 2>&1

  if [ "$goal" = 1 ]; then
    echo "device_verdict=PASS" >> "$dev"
    echo ".$tag PASS goal_in=${hit}s ($model iOS $ios)"
    return 0
  fi
  echo "device_verdict=FAIL" >> "$dev"
  echo ".$tag FAIL goal_not_reached in ${TIMEOUT}s ($model iOS $ios)"
  return 1
}

printf 'device\thw_model\tmodel\tios\tscheme\tpackage\ttarget_installed\n' > "$OUT/matrix.tsv"
for i in "${!HOSTS[@]}"; do
  tag="${HOSTS[$i]}"
  echo "==== probe .$tag ===="
  probe="$(probe_device "$tag")"
  printf '%s\n' "$probe" > "$OUT/per_device/$tag.probe.txt"
  hw="$(printf '%s\n' "$probe" | sed -n 's/^hw_model=//p' | head -1)"
  ios="$(printf '%s\n' "$probe" | sed -n 's/^ios=//p' | head -1)"
  scheme="$(printf '%s\n' "$probe" | sed -n 's/^scheme=//p' | head -1)"
  pkg="$(printf '%s\n' "$probe" | sed -n 's/^pkg=//p' | head -1)"
  inst="$(printf '%s\n' "$probe" | sed -n 's/^target_installed=//p' | head -1)"
  [ -z "$inst" ] && inst="0"
  [ -z "$ios" ] && ios="unknown"
  model="$(model_name "$hw")"
  echo "  hw=$hw model=$model ios=$ios scheme=$scheme target_installed=$inst"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$hw" "$model" "$ios" "$scheme" "$pkg" "$inst" >> "$OUT/matrix.tsv"
  [ "$i" -lt $(( ${#HOSTS[@]} - 1 )) ] && sleep "$STAGGER"
done

FAILN=0
SKIPN=0
for i in "${!HOSTS[@]}"; do
  tag="${HOSTS[$i]}"
  model="$(awk -F'\t' -v t="$tag" '$1==t{print $3}' "$OUT/matrix.tsv")"
  ios="$(awk -F'\t' -v t="$tag" '$1==t{print $4}' "$OUT/matrix.tsv")"
  scheme="$(awk -F'\t' -v t="$tag" '$1==t{print $5}' "$OUT/matrix.tsv")"
  pkg="$(awk -F'\t' -v t="$tag" '$1==t{print $6}' "$OUT/matrix.tsv")"
  inst="$(awk -F'\t' -v t="$tag" '$1==t{print $7}' "$OUT/matrix.tsv")"
  if [ "$inst" != "1" ]; then
    {
      echo "device=.$tag"
      echo "hw_model=$model"
      echo "ios=$ios"
      echo "scheme=$scheme"
      echo "package=$pkg"
      echo "script_sha256=$SCRIPT_SHA"
      echo "# 该机未安装目标 App $BID：无法参与本脚本的通用性比对"
      echo "device_verdict=SKIP_TARGET_NOT_INSTALLED"
    } > "$OUT/per_device/$tag.txt"
    echo ".$tag SKIP 目标 App $BID 未安装 ($model iOS $ios)"
    SKIPN=$((SKIPN+1))
    [ "$i" -lt $(( ${#HOSTS[@]} - 1 )) ] && sleep "$STAGGER"
    continue
  fi
  run_device "$tag" "$model" "$ios" "$scheme" "$pkg" || FAILN=$((FAILN+1))
  [ "$i" -lt $(( ${#HOSTS[@]} - 1 )) ] && sleep "$STAGGER"
done

PASSN=0
{
  echo "# 通用性验收（同一份业务脚本跨机型 / 跨 iOS）"
  echo
  echo "脚本：\`$SCRIPT_NAME\`  sha256=\`${SCRIPT_SHA:0:32}…\`  ${SCRIPT_SIZE} bytes"
  echo "目标 App：\`$BID\`   每机超时：${TIMEOUT}s"
  echo
  echo "## 判定"
  echo
  echo "| 设备 | 机型 | iOS | scheme | 包 | 脚本 sha 一致 | 判定 | 达成耗时 |"
  echo "|---|---|---|---|---|---|---|---|"
} > "$OUT/REPORT.md"
for i in "${!HOSTS[@]}"; do
  tag="${HOSTS[$i]}"
  d="$OUT/per_device/$tag.txt"
  v="$(sed -n 's/^device_verdict=//p' "$d" 2>/dev/null | tail -1)"
  rs="$(sed -n 's/^remote_sha256=//p' "$d" 2>/dev/null | tail -1)"
  tg="$(sed -n 's/^time_to_goal_sec=//p' "$d" 2>/dev/null | tail -1)"
  same="no"; [ "$rs" = "$SCRIPT_SHA" ] && same="yes"
  [ "$v" = PASS ] && PASSN=$((PASSN+1))
  [ "$v" = SKIP_TARGET_NOT_INSTALLED ] && same="n/a"
  model="$(awk -F'\t' -v t="$tag" '$1==t{print $3}' "$OUT/matrix.tsv")"
  ios="$(awk -F'\t' -v t="$tag" '$1==t{print $4}' "$OUT/matrix.tsv")"
  scheme="$(awk -F'\t' -v t="$tag" '$1==t{print $5}' "$OUT/matrix.tsv")"
  pkg="$(awk -F'\t' -v t="$tag" '$1==t{print $6}' "$OUT/matrix.tsv")"
  echo "| \`.$tag\` | $model | $ios | $scheme | $pkg | $same | ${v:-MISSING} | ${tg:-} |" >> "$OUT/REPORT.md"
done

{
  echo
  echo "## 矩阵覆盖（iPhone 7 / 7P / 8 / 8P × iOS 13~17）"
  echo
  echo "本轮真机覆盖到的格子："
  echo
} >> "$OUT/REPORT.md"
COVER=""
for i in "${!HOSTS[@]}"; do
  tag="${HOSTS[$i]}"
  model="$(awk -F'\t' -v t="$tag" '$1==t{print $3}' "$OUT/matrix.tsv")"
  ios="$(awk -F'\t' -v t="$tag" '$1==t{print $4}' "$OUT/matrix.tsv")"
  echo "- $model × iOS $ios  （\`.$tag\`）" >> "$OUT/REPORT.md"
  COVER="$COVER $model:$ios"
done
{
  echo
  echo "**未覆盖**（无真机，不得写成 PASS，也不得当成 FAIL）："
  echo
} >> "$OUT/REPORT.md"
for m in iPhone7 iPhone7Plus iPhone8 iPhone8Plus; do
  case "$COVER" in
    *"$m:"*) ;;
    *) echo "- 机型 $m：无真机" >> "$OUT/REPORT.md" ;;
  esac
done
for maj in 13 14 15 16 17; do
  case "$COVER" in
    *":$maj"*) ;;
    *":$maj."*) ;;
    *) echo "- iOS $maj.x：无真机" >> "$OUT/REPORT.md" ;;
  esac
done

{
  echo
  echo "## 结论"
  echo
  if [ "$FAILN" -eq 0 ] && [ "$PASSN" -eq "${#HOSTS[@]}" ]; then
    echo "- 本轮真机：**【同一份脚本】全部自己达成目标**（$PASSN/${#HOSTS[@]}）。"
  else
    echo "- 本轮真机：**未全通过**（$PASSN/${#HOSTS[@]} 达成，$FAILN 未达成）。"
    echo "- 未达成的机器说明该脚本依赖了机型/系统相关的固定前提（例如桌面图标坐标）。"
  fi
  echo "- 矩阵覆盖 ≠ 矩阵完成：只有覆盖到的机型×系统格子可判；未覆盖格子保持未验证。"
  echo "- 口径：必须由脚本自身路径跑通；先人工摆好前台/先开 App 再跑，不计入。"
} >> "$OUT/REPORT.md"

# 判定口径：SKIP（未装目标 App）既不算 PASS 也不算 FAIL，
# 只有「全部设备都跑到且都自己达成」才是真 PASS。
if [ "$FAILN" -eq 0 ] && [ "$SKIPN" -eq 0 ] && [ "$PASSN" -eq "${#HOSTS[@]}" ]; then
  echo "UNIVERSAL_SCRIPT=PASS devices=$PASSN/${#HOSTS[@]}"
elif [ "$FAILN" -eq 0 ]; then
  echo "UNIVERSAL_SCRIPT=INCOMPLETE pass=$PASSN skip=$SKIPN total=${#HOSTS[@]}"
else
  echo "UNIVERSAL_SCRIPT=FAIL pass=$PASSN fail=$FAILN skip=$SKIPN total=${#HOSTS[@]}"
fi
printf 'gate=universal_script\nscript_sha256=%s\ntarget_bid=%s\ndevices=%s\npass=%s\nfail=%s\nskip=%s\ntotal=%s\n' \
  "$SCRIPT_SHA" "$BID" "${HOSTS[*]}" "$PASSN" "$FAILN" "$SKIPN" "${#HOSTS[@]}" > "$OUT/SUMMARY.txt"
cat "$OUT/SUMMARY.txt"
echo "REPORT=$OUT/REPORT.md"
