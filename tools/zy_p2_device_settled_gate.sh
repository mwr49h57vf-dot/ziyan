#!/bin/sh
# 设备侧 P2 门禁：常驻业务找色保持运行时，重复 App ↔ Home 并被动读本机
# /status。长窗放在手机本机执行，避免宿主终端回收后台任务后只留下“半轮”假结果。
set +e

V=/usr/lib/ziyan/var
M=/private/var/mobile/Media/ZiYan
BID="${1:-com.ownbook.notes}"
CYCLES="${2:-6}"
AGE_MAX="${ZY_FG_AGE_MAX:-1200}"
SAMPLES="${ZY_P2_SAMPLES:-6}"
SAMPLE_SLEEP="${ZY_P2_SAMPLE_SLEEP:-1}"
# Home 的稳定性不能只看“刚切到桌面”的瞬间：.112 曾在约 5 秒内从桌面
# 回弹到业务 App。默认等待 6 秒，覆盖产品侧 2.25s/5.25s post-home guard。
HOME_STABLE="${ZY_P2_HOME_STABLE_S:-6}"
TAG="${ZY_P2_TAG:-device}"
OUT="$V/.ziyan_p2_${TAG}_settled_$(date '+%Y%m%d_%H%M%S').txt"
PIDF="$M/p2_${TAG}_settled.pid"

echo $$ >"$PIDF"
chmod 666 "$PIDF" 2>/dev/null
# Media 目录会被部分业务清理逻辑扫掉；P2 证据必须留在 ZiYan var，且脚本本身
# 直接重定向到该文件，宿主断连或 nohup stdout 回收都不影响结论。
exec >>"$OUT" 2>&1

# 清掉前一轮 Home/Play 留下的 App 侧触发旗。旧 suspend trig 会被 ZiYan
# App 的 250ms poller 当成新请求，在 open_app 后立即再次挂起目标 App，造成
# front=目标但 shm 仍是 SpringBoard 的假 P2 失败。
rm -f "$V/.ziyan_app_suspend_trig" "$V/.ziyan_app_run_trig" \
      "$V/.ziyan_app_stop_trig" "$V/.ziyan_app_minimize_req"

status() { /usr/bin/wget -qO- http://127.0.0.1:50005/status 2>/dev/null; }
val() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1 | tr -d '\r'; }

go_home() {
  echo 1 >"$V/.ziyan_go_home"
  chmod 666 "$V/.ziyan_go_home" 2>/dev/null
  # .112 实机完成 Home 激活约需 5 秒。旧逻辑 1.5 秒就撤请求，门禁会在
  # SpringBoard 尚未确认前把“请求未完成”误报为产品失败。保持旗标直到前台
  # 归属实际变为 SpringBoard，最长 16 秒；仅在成功/超时后清理该次请求。
  i=0
  while [ "$i" -lt 16 ]; do
    f=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
    case "$f" in
      *springboard*)
        rm -f "$V/.ziyan_go_home"
        return 0
        ;;
    esac
    sleep 1
    i=$((i + 1))
  done
  rm -f "$V/.ziyan_go_home"
  return 1
}

open_app() {
  rm -f "$V/.ziyan_app_user_closed"
  printf '%s\n' "$BID" >"$V/.ziyan_open_app"
  # P2 只通过运行时控制通道投递 activation。Media 下的同名文件会被
  # 另一条历史轮询路径再次消费；它可能在 Home 状态机已经完成后重放 open，
  # 造成“回桌面后又自动回 App”的测试污染。业务兼容路径仍保留在产品代码，
  # 但不应由这个前台切换门禁同时写入。
  chmod 666 "$V/.ziyan_open_app" 2>/dev/null
  i=0
  while [ "$i" -lt 20 ]; do
    f=$(tr -d '\r\n' <"$V/.ziyan_front_bid" 2>/dev/null)
    # 若目标本来就在前台，前台文件会在控制桥消费新请求之前就匹配；必须
    # 撤回这张尚未消费的 activation 票，否则下一次 Home 时 poller 才读到它，
    # 造成“刚回桌面又被 open_app 拉回”的门禁自污染。
    [ "$f" = "$BID" ] && {
      rm -f "$V/.ziyan_open_app"
      echo "$i"
      return 0
    }
    sleep 1
    i=$((i + 1))
  done
  echo "$i"
  return 1
}

echo "# P2 $TAG settled foreground gate"
echo "bid=$BID cycles=$CYCLES samples_per_app=$SAMPLES sample_sleep_s=$SAMPLE_SLEEP age_max_ms=$AGE_MAX home_stable_s=$HOME_STABLE"
echo "started=$(date '+%Y-%m-%d %H:%M:%S')"
fails=0

for c in $(seq 1 "$CYCLES"); do
  go_home
  sleep "$HOME_STABLE"
  ready=$(open_app)
  open_rc=$?
  sleep 4
  s=0
  while [ "$s" -lt "$SAMPLES" ]; do
    # shm writer 在 commit_seq 奇数窗口会主动拒读，/status 暂时返回
    # seq=0/age=-1/provider=0。它是半帧保护而不是业务失败；立即重读最多
    # 两次，并把次数写入证据。持续无效仍按 FAIL 处理。
    sample_retry=0
    while :; do
      st=$(status)
      age=$(val "$st" frame_age_ms); seq=$(val "$st" frame_seq)
      provider=$(val "$st" frame_provider); front=$(val "$st" front_bid)
      shm=$(val "$st" shm_bid)
      invalid_meta=0
      case "$age" in *[!0-9]*|'') invalid_meta=1 ;; esac
      [ "$seq" -gt 0 ] 2>/dev/null || invalid_meta=1
      [ "$provider" -gt 0 ] 2>/dev/null || invalid_meta=1
      [ "$invalid_meta" = 0 ] || [ "$sample_retry" -ge 2 ] || {
        sample_retry=$((sample_retry + 1))
        sleep 0.2
        continue
      }
      break
    done
    [ -n "$age" ] || age=-1; [ -n "$seq" ] || seq=-1
    [ -n "$provider" ] || provider=-; [ -n "$front" ] || front=-
    [ -n "$shm" ] || shm=-
    line="cycle=$c stage=app sample=$s retry=$sample_retry ready_s=$ready age_ms=$age seq=$seq provider=$provider front=$front shm_bid=$shm"
    bad=0
    [ "$open_rc" = 0 ] || bad=1
    case "$age" in *[!0-9]*|'') bad=1 ;; *) [ "$age" -le "$AGE_MAX" ] 2>/dev/null || bad=1 ;; esac
    [ "$front" = "$BID" ] || bad=1
    [ "$shm" = "$BID" ] || bad=1
    if [ "$bad" = 1 ]; then line="$line FAIL"; fails=$((fails + 1)); else line="$line PASS"; fi
    echo "$line"
    s=$((s + 1))
    [ "$s" -lt "$SAMPLES" ] && sleep "$SAMPLE_SLEEP"
  done

  go_home
  sleep "$HOME_STABLE"
  home_retry=0
  while :; do
    hs=$(status)
    hage=$(val "$hs" frame_age_ms); hseq=$(val "$hs" frame_seq)
    hfront=$(val "$hs" front_bid); hshm=$(val "$hs" shm_bid)
    invalid_home_meta=0
    case "$hage" in *[!0-9]*|'') invalid_home_meta=1 ;; esac
    [ "$hseq" -gt 0 ] 2>/dev/null || invalid_home_meta=1
    [ "$invalid_home_meta" = 0 ] || [ "$home_retry" -ge 2 ] || {
      home_retry=$((home_retry + 1))
      sleep 0.2
      continue
    }
    break
  done
  [ -n "$hage" ] || hage=-1; [ -n "$hseq" ] || hseq=-1
  [ -n "$hfront" ] || hfront=-; [ -n "$hshm" ] || hshm=-
  hline="cycle=$c stage=home retry=$home_retry age_ms=$hage seq=$hseq front=$hfront shm_bid=$hshm"
  hbad=0
  case "$hage" in *[!0-9]*|'') hbad=1 ;; *) [ "$hage" -le "$AGE_MAX" ] 2>/dev/null || hbad=1 ;; esac
  [ "$hfront" = "com.apple.springboard" ] || hbad=1
  [ "$hshm" = "com.apple.springboard" ] || hbad=1
  if [ "$hbad" = 1 ]; then hline="$hline FAIL"; fails=$((fails + 1)); else hline="$hline PASS"; fi
  echo "$hline"
done

echo "FAILS=$fails"
[ "$fails" = 0 ] && echo "VERDICT=PASS" || echo "VERDICT=FAIL"
rm -f "$PIDF"
