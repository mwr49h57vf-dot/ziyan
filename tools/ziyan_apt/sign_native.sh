#!/bin/bash
# 用 .101 真实 gpg + 本地自签原生密钥给仓库签名（绕过 Mac 无 gpg / pgpy 兼容性问题）
# 私钥：~/.ziyan_keys/apt-native-priv.asc（600，仅本机）；设备上有同源密钥 apt@ziyan.local
# 用法：bash tools/ziyan_apt/sign_native.sh [repo_dir，默认 ziyan_apt_repo]
set -u
REPO="${1:-ziyan_apt_repo}"
cd "$(dirname "$0")/../.." 2>/dev/null || cd /Users/mac/Desktop/ZiYan_副本
REL="$REPO/dists/stable/Release"
[ -f "$REL" ] || { echo "NO_RELEASE $REL"; exit 1; }
sshpass -p alpine scp -q "$REL" root@192.168.31.101:/tmp/sign_Release
sshpass -p alpine ssh -o ConnectTimeout=8 root@192.168.31.101 'cd /tmp && rm -f sign_Release.gpg sign_InRelease && gpg --batch --yes --local-user apt@ziyan.local --detach-sign -o sign_Release.gpg sign_Release && gpg --batch --yes --local-user apt@ziyan.local --clearsign -o sign_InRelease sign_Release && gpg --batch --verify sign_Release.gpg sign_Release 2>&1 | grep -E "Good|BAD"'
sshpass -p alpine scp -q root@192.168.31.101:/tmp/sign_Release.gpg "$REPO/dists/stable/Release.gpg"
sshpass -p alpine scp -q root@192.168.31.101:/tmp/sign_InRelease "$REPO/dists/stable/InRelease"
echo "SIGNED_NATIVE key=apt@ziyan.local repo=$REPO"
ls -la "$REPO/dists/stable/Release.gpg" "$REPO/dists/stable/InRelease"
