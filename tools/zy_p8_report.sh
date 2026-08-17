#!/usr/bin/env bash
# P8：C98 同包总报告。只汇总已有证据 + 只读 dpkg / 触动观察。
# 生成报告不是产品 PASS，更不是超越触动。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT="$ROOT/tmp_shots/P8_TOTAL_REPORT_${STAMP}.md"
PASS="${ZY_SSH_PASS:-alpine}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=10 -o PreferredAuthentications=password
          -o PubkeyAuthentication=no)
C98_SHA=5c956619c26726e13635d804a3c085afce16d8dcd9bef7d7e57c1316dc1479c9
C98_VER=0.0.92-8-161-205-C-65.11-98+debug-1+debug

latest_dir() {
  local pat="$1" d
  d=$(find "$ROOT/tmp_shots" -maxdepth 1 -type d -name "$pat" -print 2>/dev/null | sort | tail -1)
  printf '%s' "$d"
}

P2_EFF="$(latest_dir 'P2_FIND_EFF_C98_*')"
P3="$(latest_dir 'OCR_GOLD_RUN_20260813_C96')"
P5_3H="$(latest_dir 'P5_3H_C96_*_101')"
P5_HOME="$(latest_dir 'P5_C98_HOME10B_*')"
P6="$(latest_dir 'P6_UICREATE_GATE_*_101')"
TOAST="$(latest_dir 'TOAST_LOCK_GATE_*_101')"
P7="$(find "$ROOT/tmp_shots" -maxdepth 1 -type d -name 'TS171_BIZ_READONLY_*' -print 2>/dev/null | sort -r | while IFS= read -r d; do [ -f "$d/summary.json" ] && { printf '%s\n' "$d"; break; }; done)"
P7_CMP="$(latest_dir 'P7_SAMEWIN_C98_*')"
C93_101="$(latest_dir 'P2_30M_C93_*_101')"
C93_112="$(latest_dir 'P2_30M_C93_*_112')"
C93_166="$(latest_dir 'P2_30M_C93_*_166')"

kv() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1 | tr -d '\r'; }

device_version() {
  local host="$1" ip="192.168.31.$1" out="" try
  for try in 1 2 3; do
    out=$(sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$ip" \
      "dpkg -s com.ziyan.ziyan 2>/dev/null | sed -n 's/^Version: //p' | head -1" 2>/dev/null || true)
    out=$(printf '%s' "$out" | tr -d '\r\n')
    [ -n "$out" ] && break
    sleep "$try"
  done
  printf '%s' "${out:-unreachable_or_unknown}"
}

ts_obs() {
  local host="$1" dest="$2"
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@192.168.31.$host" \
    'echo HOST='$host'; date "+TS=%Y-%m-%d %H:%M:%S %z"; echo RUNCFG=$(tr "\n" " " </var/mobile/Media/TouchSprite/config/run.cfg 2>/dev/null | head -c 160); ps -axo pid=,rss=,%cpu=,etime=,args= | while read -r pid rss cpu etime args; do case "$args" in *TSDaemon\ -server*) echo ROLE=TSDaemon PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; */System/Library/CoreServices/SpringBoard.app/SpringBoard*) echo ROLE=SpringBoard PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; *FGCQLibClient-mobile*) echo ROLE=App PID=$pid RSS=$rss CPU=$cpu ETIME=$etime;; esac; done' \
    >"$dest" 2>&1 || echo "SSH_FAIL host=$host" >>"$dest"
}

DEPLOY_101="$(device_version 101)"
DEPLOY_112="$(device_version 112)"
DEPLOY_166="$(device_version 166)"

TS_DIR="$ROOT/tmp_shots/TS_OBS/${STAMP}"
mkdir -p "$TS_DIR"
ts_obs 171 "$TS_DIR/171.txt" &
p171=$!
ts_obs 149 "$TS_DIR/149.txt" &
p149=$!
wait $p171 $p149 || true

P2_EFF_V=MISSING
[ -n "$P2_EFF" ] && [ -f "$P2_EFF/VERDICT.md" ] && P2_EFF_V="$(kv VERDICT "$P2_EFF/VERDICT.md")"
P3_V=MISSING
[ -n "$P3" ] && [ -f "$P3/VERDICT.md" ] && P3_V="$(kv VERDICT "$P3/VERDICT.md")"
P6_V=MISSING
[ -n "$P6" ] && [ -f "$P6/REPORT.md" ] && grep -q '三机' "$P6/REPORT.md" && P6_V=PASS
TOAST_V=MISSING
[ -n "$TOAST" ] && [ -f "$TOAST/REPORT.md" ] && grep -q 'PASS' "$TOAST/REPORT.md" && TOAST_V=PASS
P7_V=MISSING
[ -n "$P7" ] && grep -q COMPARISON_COMPLETE "$P7/summary.json" 2>/dev/null && P7_V=COMPARISON_COMPLETE
P5_3H_V=FAIL
P5_HOME_V=MISSING
[ -n "$P5_HOME" ] && [ -f "$P5_HOME/REPORT.md" ] && grep -q '10/10 PASS' "$P5_HOME/REPORT.md" && P5_HOME_V=PASS

P2_STATUS=IN_PROGRESS
P8_STATUS=REPORT_COMPLETE_NOT_FINAL
# 总报告可出，但不能把 P2/P5 未收口写成产品全绿。
if [ "$P2_EFF_V" != PASS ] || [ "$P3_V" != PASS ] || [ "$P6_V" != PASS ] || \
   [ "$P7_V" != COMPARISON_COMPLETE ] || [ "$TOAST_V" != PASS ] || [ "$P5_HOME_V" != PASS ]; then
  P8_STATUS=REPORT_INCOMPLETE_EVIDENCE
fi

{
  echo "# ZiYan P8 总报告（C98 同包）"
  echo
  echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "部署范围：ZiYan 验收 .53/.101/.112/.166；.149/.171 只读。"
  echo "账本包：$C98_VER"
  echo "账本 SHA-256：$C98_SHA"
  echo
  echo "**本文件是证据汇总。P8 不是产品全绿，禁止宣称超越触动。**"
  echo
  echo "## 阶段判定（与 CURRENT_ISSUES 对齐）"
  echo
  echo "| 阶段 | 判定 | 证据 |"
  echo "|---|---|---|"
  echo "| P2 总 | IN_PROGRESS | 效率 C98 PASS；Gate C 30m 仍是 C93，未在 C98 重跑 |"
  echo "| P2 效率 | ${P2_EFF_V:-MISSING} | ${P2_EFF:-未找到} |"
  echo "| Gate C 30m | PASS (C93) | $C93_101 ; $C93_112 ; $C93_166 |"
  echo "| P3 OCR | ${P3_V:-MISSING} | ${P3:-未找到} |"
  echo "| P5 3h | FAIL (C96) | ${P5_3H:-未找到}；用户决定不再开 180m |"
  echo "| P5 Home10B | ${P5_HOME_V:-MISSING} | ${P5_HOME:-未找到} |"
  echo "| P6 UICreate | ${P6_V:-MISSING} | ${P6:-未找到} |"
  echo "| Toast+锁屏 | ${TOAST_V:-MISSING} | ${TOAST:-未找到} |"
  echo "| P7 同窗 | ${P7_V:-MISSING} | ${P7:-未找到} / ${P7_CMP:-} |"
  echo "| P8 | $P8_STATUS | 本文件 |"
  echo
  echo "## 真机版本（只读 dpkg）"
  echo
  echo "- .101=$DEPLOY_101"
  echo "- .112=$DEPLOY_112"
  echo "- .166=$DEPLOY_166"
  echo "- 期望 C98：$C98_VER"
  echo
  echo "## P2 效率（C98）"
  echo
  if [ -n "$P2_EFF" ] && [ -f "$P2_EFF/VERDICT.md" ]; then
    cat "$P2_EFF/VERDICT.md"
  else
    echo "未找到 P2_FIND_EFF_C98。"
  fi
  echo
  echo "## P3 OCR（C96）"
  echo
  if [ -n "$P3" ]; then
    echo "证据：$P3"
    [ -f "$P3/VERDICT.md" ] && cat "$P3/VERDICT.md"
    [ -f "$P3/SUMMARY.tsv" ] && { echo; echo '```tsv'; cat "$P3/SUMMARY.tsv"; echo '```'; }
  else
    echo "未找到 OCR_GOLD_RUN_20260813_C96。"
  fi
  echo
  echo "## P5"
  echo
  echo "### 3h（C96，仍 FAIL）"
  if [ -n "$P5_3H" ] && [ -f "$P5_3H/REPORT.md" ]; then
    echo "证据：$P5_3H"
    sed -n '1,20p' "$P5_3H/REPORT.md"
  fi
  echo
  echo "### Home10B（C98，10/10，不能代替 3h）"
  if [ -n "$P5_HOME" ] && [ -f "$P5_HOME/REPORT.md" ]; then
    echo "证据：$P5_HOME"
    sed -n '1,28p' "$P5_HOME/REPORT.md"
  fi
  echo
  echo "## P6 UICreate（C98）"
  echo
  if [ -n "$P6" ] && [ -f "$P6/REPORT.md" ]; then
    cat "$P6/REPORT.md"
  fi
  echo
  echo "## Toast + 锁屏（C98）"
  echo
  if [ -n "$TOAST" ] && [ -f "$TOAST/REPORT.md" ]; then
    cat "$TOAST/REPORT.md"
  fi
  echo
  echo "## P7 同窗（C98 vs .171/.149）"
  echo
  if [ -n "$P7" ]; then
    echo "证据：$P7"
    echo '```json'
    cat "$P7/summary.json"
    echo '```'
  fi
  if [ -n "$P7_CMP" ] && [ -f "$P7_CMP/COMPARE.md" ]; then
    echo
    echo "对照：$P7_CMP"
    sed -n '1,40p' "$P7_CMP/COMPARE.md"
  fi
  echo
  echo "触动内部 find 耗时不可从 HTTP/外部模板读取。COMPARISON_COMPLETE ≠ 超越。"
  echo
  echo "## 本窗触动只读"
  echo
  echo "目录：$TS_DIR"
  echo
  echo "### .171"
  echo '```text'
  grep -E 'HOST=|TS=|RUNCFG=|ROLE=|SSH_FAIL' "$TS_DIR/171.txt" | head -12
  echo '```'
  echo
  echo "### .149"
  echo '```text'
  grep -E 'HOST=|TS=|RUNCFG=|ROLE=|SSH_FAIL|Permission' "$TS_DIR/149.txt" | head -12
  echo '```'
  echo
  echo "## 回滚"
  echo
  echo "- 只允许在 .101/.112/.166 上回滚上一核验 deb。默认禁止 sbreload/killall SpringBoard（BLOCKED_AUTO_SB_RESTART）。"
  echo "- 不触碰 .53/.149/.171。不升级 .53。不开 BBFrame。"
  echo
  echo "## 复跑入口（现包，不默认装包）"
  echo
  echo '```sh'
  echo 'bash tools/zy_p2_find_eff_gate.sh 101 112 166'
  echo 'ZY_OCR_REPEAT=5 bash tools/zy_ocr_gold_gate.sh 101 112 166'
  echo 'bash tools/zy_p6_uicreate_gate.sh 101'
  echo 'bash tools/zy_toast_lock_gate.sh 101'
  echo 'bash tools/zy_p7_samewin_gate.sh'
  echo 'bash tools/zy_p8_report.sh'
  echo '```'
  echo
  echo "## 总判定"
  echo
  echo "P2=IN_PROGRESS（效率 $P2_EFF_V；30m 仍 C93）。"
  echo "P3=$P3_V。"
  echo "P5_3h=FAIL（C96）；P5_Home10B=$P5_HOME_V。"
  echo "P6=$P6_V。"
  echo "Toast=$TOAST_V。"
  echo "P7=$P7_V。"
  echo "P8=$P8_STATUS。"
  echo
  echo "禁止：把本报告写成 P2 全绿、P5 已收口、或已超越触动。"
} >"$OUT"

echo "OUT=$OUT"
echo "P8=$P8_STATUS"
echo "TS=$TS_DIR"
