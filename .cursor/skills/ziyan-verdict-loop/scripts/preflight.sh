#!/usr/bin/env bash
# Read-only ZiYan project/device summary. Never deploys, restarts, writes, or prompts.
set -u

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$ROOT" || exit 2

echo "== ZiYan verdict-loop preflight =="
echo "root=$ROOT"
echo "time=$(date '+%Y-%m-%d %H:%M:%S %z')"

echo ""
echo "-- current handoff --"
sed -n '1,40p' 今日项目进度.txt 2>/dev/null || echo "MISSING 今日项目进度.txt"

echo ""
echo "-- active gates --"
sed -n '/## 4\. 当前状态/,/## 5\./p' ROADMAP.md 2>/dev/null | sed -n '1,40p'

echo ""
echo "-- workspace --"
git status --short 2>/dev/null | sed -n '1,30p'
find packages -maxdepth 1 -type f -name '*.deb' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -5

probe() {
  local tag="$1" ip="$2" var="$3"
  local out
  out=$(ssh -n -o BatchMode=yes -o PasswordAuthentication=no \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
    "root@$ip" "V='$var'; \
      printf 'os='; sw_vers -productVersion 2>/dev/null; \
      printf ' pkg='; dpkg -l com.ziyan.ziyan 2>/dev/null | sed -n 's/^ii  com.ziyan.ziyan  *\\([^ ]*\\).*/\\1/p' | head -1; \
      printf ' fc='; ps -ax -o command= 2>/dev/null | grep -F 'ziyan_framecap serve' | grep -vc grep | tr -d ' '; \
      printf ' sb='; ps -ax -o command= 2>/dev/null | grep -F '/SpringBoard.app/SpringBoard' | grep -vc grep | tr -d ' '; \
      printf ' session='; tr '\\n' ' ' < \"\$V/.ziyan_session\" 2>/dev/null | head -c 120" 2>&1)
  if [ $? -eq 0 ]; then
    echo "DEVICE .$tag SSH_KEY_OK $out"
  else
    echo "DEVICE .$tag TRANSPORT_BLOCKED ${out:0:180}"
  fi
}

echo ""
echo "-- four-device read-only state --"
probe 53 192.168.31.53 /var/jb/usr/lib/ziyan/var
probe 101 192.168.31.101 /usr/lib/ziyan/var
probe 112 192.168.31.112 /usr/lib/ziyan/var
probe 166 192.168.31.166 /usr/lib/ziyan/var

echo ""
echo "-- next-action reminder --"
echo "Treat TRANSPORT_BLOCKED and INVALID_RUN as test-channel work; do not change product code."
