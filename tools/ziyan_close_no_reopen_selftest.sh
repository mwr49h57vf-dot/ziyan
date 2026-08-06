#!/bin/bash
# 关闭程序后禁止自动拉起 App（复现/验收 8-161-43）
# usage: tools/ziyan_close_no_reopen_selftest.sh [53|101|112|166|all]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=alpine
want="${1:-all}"

run_one() {
  local tag="$1" ip="$2"
  echo "==== close_no_reopen .$tag $ip ===="
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 "root@$ip" "bash -s" <<EOS
set +e
VAR=/usr/lib/ziyan/var
[ -d /var/jb/usr/lib/ziyan ] && VAR=/var/jb/usr/lib/ziyan/var
echo "VER=\$(dpkg -s com.ziyan.ziyan 2>/dev/null | grep ^Version)"
# 1) 打开 App（清粘性，模拟用户手动开）
rm -f "\$VAR/.ziyan_app_user_closed" "\$VAR/.ziyan_vol_disarmed" "\$VAR/.ziyan_open_app"
uiopen -b com.ziyan.ziyan 2>/dev/null || uiopen com.ziyan.ziyan:// 2>/dev/null || true
sleep 3
# 2) 音量−「关闭程序」等价路径：.ziyan_close_app → SB ZiYanCloseApp
echo com.ziyan.ziyan > "\$VAR/.ziyan_close_app"
chmod 666 "\$VAR/.ziyan_close_app" 2>/dev/null
sleep 3
UC=0; DA=0
[ -f "\$VAR/.ziyan_app_user_closed" ] && UC=1
[ -f "\$VAR/.ziyan_vol_disarmed" ] && DA=1
ALIVE1=\$(ps -A -o args= 2>/dev/null | grep -v grep | grep -c 'ZiYan\\.app/ZiYan' || true)
echo "AFTER_CLOSE user_closed=\$UC disarmed=\$DA app_alive=\$ALIVE1"
# 3) 等 >20s（旧 bug：daemon 20s ensure_app_open retry）
sleep 22
ALIVE2=\$(ps -A -o args= 2>/dev/null | grep -v grep | grep -c 'ZiYan\\.app/ZiYan' || true)
OPEN=0; [ -f "\$VAR/.ziyan_open_app" ] && OPEN=1
UC2=0; [ -f "\$VAR/.ziyan_app_user_closed" ] && UC2=1
RETRY=\$(grep -c 'ensure_app_open retry' "\$VAR/.ziyan_daemon_log" 2>/dev/null || echo 0)
SKIP=\$(grep -E 'uiopen skip|ensure_app_open skip' "\$VAR/.ziyan_daemon_log" 2>/dev/null | tail -3 | tr '\n' ';' )
echo "AFTER_WAIT app_alive=\$ALIVE2 open_app=\$OPEN user_closed=\$UC2 retry_lines=\$RETRY skip_tail=\$SKIP"
# 通过：关闭后仍有 user_closed；等待后 App 进程=0；无 open_app 文件
if [ "\$UC" = 1 ] && [ "\$UC2" = 1 ] && [ "\$ALIVE2" = 0 ] && [ "\$OPEN" = 0 ]; then
  echo "PASS_$tag"
  exit 0
fi
echo "FAIL_$tag"
exit 1
EOS
}

fail=0
while IFS='|' read -r tag ip _pass scheme _rest; do
  [[ "$tag" =~ ^# ]] && continue
  [[ -z "$tag" ]] && continue
  [[ "$scheme" == "ts" ]] && continue
  if [[ "$want" != "all" && "$want" != "$tag" ]]; then
    continue
  fi
  if ! run_one "$tag" "$ip"; then
    fail=1
  fi
done < <(grep -v '^#' "$ROOT/DEVICES.txt" | grep '|')

if [[ "$fail" == 0 ]]; then
  echo "CLOSE_NO_REOPEN_ALL_OK"
else
  echo "CLOSE_NO_REOPEN_FAIL"
  exit 1
fi
