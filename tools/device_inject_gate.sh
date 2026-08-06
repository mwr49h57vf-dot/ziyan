#!/usr/bin/env bash
# device_inject_gate.sh — 装包/respring 后必须确认 ZiYanVol 已注入 SpringBoard
# 用法：tools/device_inject_gate.sh 192.168.31.53 [rootless|rootful]
# 通过：.ziyan_hooks 与 .ziyan_cap_diag 在近 N 秒内刷新
set -euo pipefail
IP="${1:?ip}"
SCHEME="${2:-}"
PASS=alpine
SSH=(sshpass -p "$PASS" ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 "root@$IP")
SSH_H=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 "root@$IP")

if [[ -z "$SCHEME" ]]; then
  SCHEME=$("${SSH[@]}" 'if [ -d /var/jb/usr/lib/ziyan ]; then echo rootless; else echo rootful; fi')
fi
if [[ "$SCHEME" == rootless ]]; then
  VAR=/var/jb/usr/lib/ziyan/var
  VOL=/var/jb/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.dylib
else
  VAR=/usr/lib/ziyan/var
  VOL=/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.dylib
fi

echo "GATE inject ip=$IP scheme=$SCHEME"

# On-device install_name string presence (rootless must contain /var/jb)
# 8-159 全零：dylib 可保留但 Filter 已卸；仍检查文件存在时的 install_name
if [[ "$SCHEME" == rootless ]]; then
  if [[ -f /dev/null ]]; then :; fi
  NAME_OK=$("${SSH[@]}" "if [ -f '$VOL' ]; then grep -a -o '/var/jb/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.dylib' '$VOL' | head -1; else echo SKIP_NO_DYLIB; fi" || true)
  if [[ "$NAME_OK" == SKIP_NO_DYLIB ]]; then
    echo "PASS skip install_name (dylib absent / full-zero)"
  elif [[ "$NAME_OK" != /var/jb/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.dylib ]]; then
    echo "FAIL: on-device ZiYanVol.dylib missing /var/jb install_name string — 勿交付，须 clean 重打 rootless 包" >&2
    exit 2
  else
    echo "PASS on-device install_name string"
  fi
fi

# Fresh inject markers + sb_pid 与当前 SpringBoard 对齐（防旧 hooks 假阳性）
# 8-159：.ziyan_zero_sb_full → 允许无 ZiYanVol hooks（全零）；验收 framecap+daemon
RESULT=$("${SSH_H[@]}" "bash -s" <<EOS
set +e
VAR=$VAR
now=\$(date +%s)
ok=1
FULL=0
[ -f "\$VAR/.ziyan_zero_sb_full" ] && FULL=1
if [ "\$FULL" = 1 ]; then
  THIN=0
  [ -f "\$VAR/.ziyan_sb_vol_thin" ] && [ ! -f "\$VAR/.ziyan_sb_vol_thin_off" ] && THIN=1
  if [ "\$THIN" = 1 ]; then
    echo "MODE=zero_sb_full+sb_vol_thin"
  else
    echo "MODE=zero_sb_full"
  fi
  fa="\$VAR/.ziyan_framecap_alive"
  if [ ! -f "\$fa" ]; then
    echo "MISSING framecap_alive"
    ok=0
  else
    mt=\$(stat -c %Y "\$fa" 2>/dev/null || stat -f %m "\$fa" 2>/dev/null || echo 0)
    age=\$((now - mt))
    echo "framecap_alive age=\${age}s"
    [ "\$age" -gt 120 ] && echo "STALE framecap_alive" && ok=0
  fi
  if [ -f "\$VAR/.ziyan_daemon_v2" ]; then
    dv=\$(cat "\$VAR/.ziyan_daemon_v2" 2>/dev/null | tr -d '\\n\\r')
    echo "daemon_v2=\$dv"
  else
    # 兼容：旧退出路径竞态会抹标；有 ObjC ziyadaemond 进程仍算活
    if ps -A -o args= 2>/dev/null | grep -v grep | grep -q '[z]iyadaemond'; then
      echo "WARN daemon_v2 missing but ziyadaemond alive"
    else
      echo "MISSING daemon_v2"; ok=0
    fi
  fi
  if [ "\$THIN" = 1 ]; then
    # thin：必须保留 ZiYanVol Filter，且 hooks 声明 volume_menu_only
    VOL_PLIST=0
    for p in /Library/MobileSubstrate/DynamicLibraries/ZiYanVol.plist \
             /var/jb/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.plist; do
      [ -f "\$p" ] && VOL_PLIST=1
    done
    if [ "\$VOL_PLIST" != 1 ]; then
      echo "FAIL ZiYanVol_filter_missing_for_thin"; ok=0
    else
      echo "PASS ZiYanVol_filter_thin"
    fi
    if [ -f "\$VAR/.ziyan_hooks" ]; then
      mt=\$(stat -c %Y "\$VAR/.ziyan_hooks" 2>/dev/null || stat -f %m "\$VAR/.ziyan_hooks" 2>/dev/null || echo 0)
      age=\$((now - mt))
      echo "hooks age=\${age}s"
      if grep -q 'volume_menu_only\\|sb_vol_thin=1' "\$VAR/.ziyan_hooks" 2>/dev/null; then
        echo "PASS volume_menu_only"
      else
        echo "WARN hooks not yet thin (may need respring)"
      fi
    else
      echo "WARN missing hooks (wait respring)"
    fi
  else
    # 纯全零：ZiYanVol filter 应已卸；FrameRelay 可提供 hooks
    for p in /Library/MobileSubstrate/DynamicLibraries/ZiYanVol.plist \
             /var/jb/Library/MobileSubstrate/DynamicLibraries/ZiYanVol.plist; do
      [ -f "\$p" ] && echo "FAIL ZiYanVol_filter_still_active \$p" && ok=0
    done
    if [ -f "\$VAR/.ziyan_hooks" ]; then
      mt=\$(stat -c %Y "\$VAR/.ziyan_hooks" 2>/dev/null || stat -f %m "\$VAR/.ziyan_hooks" 2>/dev/null || echo 0)
      age=\$((now - mt))
      echo "hooks age=\${age}s (FrameRelay)"
      grep -q 'relay_only=1' "\$VAR/.ziyan_hooks" 2>/dev/null && echo "PASS relay_only"
    fi
  fi
else
  for f in .ziyan_hooks .ziyan_cap_diag; do
    p="\$VAR/\$f"
    if [ ! -f "\$p" ]; then
      echo "MISSING \$f"
      ok=0
      continue
    fi
    mt=\$(stat -c %Y "\$p" 2>/dev/null || stat -f %m "\$p" 2>/dev/null || echo 0)
    age=\$((now - mt))
    echo "\$f age=\${age}s"
    if [ "\$age" -gt 300 ]; then
      echo "STALE \$f"
      ok=0
    fi
  done
  SB=\$(ps -A -o pid=,args= | grep 'SpringBoard.app/SpringBoard' | grep -v grep | head -1 | sed 's/^ *//;s/ .*//')
  HP=\$(grep -E '^sb_pid=' "\$VAR/.ziyan_hooks" 2>/dev/null | head -1 | sed 's/sb_pid=//')
  echo "SB=\$SB hooks_pid=\$HP"
  if [ -n "\$SB" ] && [ -n "\$HP" ] && [ "\$SB" != "\$HP" ]; then
    echo "PID_MISMATCH hooks 过期（SB 已换 pid）"
    ok=0
  fi
fi
if [ -f /var/mobile/.eksafemode ]; then
  echo "SAFEMODE .eksafemode present"
  ok=0
fi
if [ "\$ok" = 1 ]; then echo INJECT_GATE_PASS; else echo INJECT_GATE_FAIL; fi
EOS
)
echo "$RESULT"
echo "$RESULT" | grep -q INJECT_GATE_PASS
echo "PASS: inject gate $IP"
