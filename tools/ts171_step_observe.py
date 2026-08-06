#!/usr/bin/env python3
"""
.171 触动分步观察（只读，不改 main.lua / 不装 ZiYan）
协议：见登录色 → minall → 高频抓 snapshot，记录
  A 找色点(0xbd8216@1009,330) / B 登录色(0x90643b@652,443) / cksum / 相位
输出：tmp_shots/TS171_STEP_*/timeline.tsv + STEP_COMPARE.md
"""
from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import time
import urllib.request
from datetime import datetime
from io import BytesIO

from PIL import Image

IP = os.environ.get("ZY_TS_IP", "192.168.31.171")
PASS = os.environ.get("ZY_SSH_PASS", "alpine")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
STAMP = datetime.now().strftime("%Y%m%d_%H%M%S")
OUT = os.path.join(ROOT, "tmp_shots", f"TS171_STEP_{STAMP}")
os.makedirs(OUT, exist_ok=True)
os.makedirs(os.path.join(OUT, "snaps"), exist_ok=True)

# main.lua ROI（逻辑坐标，与脚本一致）
FIND_XY = (1009, 330)
FIND_RGB = (0xBD, 0x82, 0x16)
LOGIN_XY = (652, 443)
LOGIN_RGB = (0x90, 0x64, 0x3B)
TOL = 38
SNAP_URL = (
    f"http://{IP}:50005/snapshot1?ext=jpg&orient=1&compress=0.55&scale=1"
)


def ssh(cmd: str, timeout: int = 20) -> str:
    p = subprocess.run(
        [
            "sshpass",
            "-p",
            PASS,
            "ssh",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "PreferredAuthentications=password",
            "-o",
            "PubkeyAuthentication=no",
            "-o",
            f"ConnectTimeout=12",
            f"root@{IP}",
            cmd,
        ],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return (p.stdout or "") + (p.stderr or "")


def snap() -> tuple[Image.Image | None, bytes, str]:
    try:
        with urllib.request.urlopen(SNAP_URL, timeout=3.5) as r:
            data = r.read()
    except Exception as e:
        return None, b"", f"err:{e}"
    ck = hashlib.md5(data).hexdigest()[:10]
    try:
        im = Image.open(BytesIO(data)).convert("RGB")
    except Exception as e:
        return None, data, f"img:{e}"
    return im, data, ck


def near(c, target, tol=TOL) -> bool:
    return all(abs(c[i] - target[i]) <= tol for i in range(3))


def probe_roi(im: Image.Image, xy, rgb, r=2) -> tuple[bool, tuple]:
    w, h = im.size
    x, y = xy
    # 若图尺寸与常见逻辑画布不一致，按比例映射
    # 触动常见逻辑：横屏 1136x640 / 1334x750 等
    sx, sy = x, y
    if w < 900:  # 被压缩过的宽
        # 仍按绝对坐标夹取（scale=1 时通常满分辨率）
        pass
    if sx >= w or sy >= h:
        # 尝试按 1136x640 映射
        sx = int(x * w / 1136.0)
        sy = int(y * h / 640.0)
    sx = max(0, min(w - 1, sx))
    sy = max(0, min(h - 1, sy))
    px = im.load()
    hit = False
    sample = px[sx, sy]
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            xx, yy = sx + dx, sy + dy
            if 0 <= xx < w and 0 <= yy < h and near(px[xx, yy], rgb):
                hit = True
                sample = px[xx, yy]
                break
        if hit:
            break
    return hit, sample


def ts_cpu() -> str:
    out = ssh(
        "ps aux | grep '[T]SDaemon' | awk '{print $3\"%rss\"$6}' | head -1",
        timeout=8,
    )
    return out.strip().splitlines()[-1] if out.strip() else "?"


def status() -> str:
    try:
        with urllib.request.urlopen(f"http://{IP}:50005/status", timeout=2) as r:
            return r.read().decode("utf-8", "ignore").strip()[:40]
    except Exception as e:
        return f"err:{e}"


def wait_login(max_s=90) -> bool:
    t0 = time.time()
    n = 0
    while time.time() - t0 < max_s:
        n += 1
        im, data, ck = snap()
        if im is None:
            time.sleep(0.4)
            continue
        ok, sample = probe_roi(im, LOGIN_XY, LOGIN_RGB, r=3)
        path = os.path.join(OUT, "snaps", f"wait_{n:03d}_{ck}.jpg")
        if n % 5 == 1 or ok:
            open(path, "wb").write(data)
        print(
            f"WAIT_LOGIN n={n} ck={ck} size={im.size} hit={ok} sample={sample} st={status()}",
            flush=True,
        )
        if ok:
            return True
        time.sleep(0.45)
    return False


def main() -> int:
    rounds = int(os.environ.get("ZY_OBS_ROUNDS", "3"))
    after_s = float(os.environ.get("ZY_OBS_AFTER", "18"))
    meta = [
        f"ip={IP}",
        f"rounds={rounds}",
        f"after_s={after_s}",
        f"find={FIND_XY}/{FIND_RGB}",
        f"login={LOGIN_XY}/{LOGIN_RGB}",
        f"status0={status()}",
        f"cpu0={ts_cpu()}",
        f"main.lua=observe_only",
    ]
    open(os.path.join(OUT, "meta.txt"), "w").write("\n".join(meta) + "\n")
    print("OUT", OUT, flush=True)
    print("\n".join(meta), flush=True)

    # 确认脚本在跑
    st = status()
    if "f01" not in st and "f0" not in st:
        print("WARN status not f01:", st, "— 仍继续观察", flush=True)

    tsv = open(os.path.join(OUT, "timeline.tsv"), "w")
    tsv.write(
        "round\tphase\tdt_ms\tcksum\tw\th\tfind\tlogin\tfind_rgb\tlogin_rgb\tcpu\tevent\n"
    )

    for r in range(1, rounds + 1):
        print(f"\n==== ROUND {r}/{rounds} ====", flush=True)
        if not wait_login(90):
            print(f"FAIL_ROUND {r} no_login_before_min", flush=True)
            continue

        # 基线 4 帧
        for i in range(4):
            im, data, ck = snap()
            if im is None:
                continue
            fh, fr = probe_roi(im, FIND_XY, FIND_RGB)
            lh, lr = probe_roi(im, LOGIN_XY, LOGIN_RGB)
            tsv.write(
                f"{r}\tpre\t{i*100}\t{ck}\t{im.size[0]}\t{im.size[1]}\t"
                f"{int(fh)}\t{int(lh)}\t{fr}\t{lr}\t{ts_cpu()}\tbaseline\n"
            )
            open(os.path.join(OUT, "snaps", f"r{r}_pre{i}_{ck}.jpg"), "wb").write(data)
            time.sleep(0.2)

        print("MINALL", flush=True)
        t_min = time.time()
        min_out = ssh("/usr/bin/ziyan_minall; echo MIN_RC=$?", timeout=15)
        print(min_out.strip(), flush=True)
        tsv.write(
            f"{r}\tmin\t0\t-\t0\t0\t0\t0\t-\t-\t{ts_cpu()}\tminall\n"
        )
        tsv.flush()

        saw_find = False
        saw_login = False
        t_find = None
        t_login = None
        last_ck = ""
        n = 0
        while time.time() - t_min < after_s:
            n += 1
            im, data, ck = snap()
            dt = int((time.time() - t_min) * 1000)
            if im is None:
                tsv.write(
                    f"{r}\tpost\t{dt}\t?\t0\t0\t0\t0\t-\t-\t?\tsnap_fail\n"
                )
                time.sleep(0.15)
                continue
            fh, fr = probe_roi(im, FIND_XY, FIND_RGB, r=3)
            lh, lr = probe_roi(im, LOGIN_XY, LOGIN_RGB, r=3)
            ev = []
            if ck != last_ck:
                ev.append("ck_chg")
                last_ck = ck
            if fh and not saw_find:
                saw_find = True
                t_find = dt
                ev.append("FIND_FIRST")
                open(
                    os.path.join(OUT, "snaps", f"r{r}_FIND_{dt}ms_{ck}.jpg"), "wb"
                ).write(data)
            if lh and not saw_login:
                saw_login = True
                t_login = dt
                ev.append("LOGIN_FIRST")
                open(
                    os.path.join(OUT, "snaps", f"r{r}_LOGIN_{dt}ms_{ck}.jpg"), "wb"
                ).write(data)
            # 关键帧留证
            if n <= 8 or n % 4 == 0 or ev:
                open(
                    os.path.join(OUT, "snaps", f"r{r}_t{dt:05d}_{ck}.jpg"), "wb"
                ).write(data)
            cpu = ts_cpu() if (n % 5 == 1 or ev) else ""
            tsv.write(
                f"{r}\tpost\t{dt}\t{ck}\t{im.size[0]}\t{im.size[1]}\t"
                f"{int(fh)}\t{int(lh)}\t{fr}\t{lr}\t{cpu}\t{','.join(ev) or '-'}\n"
            )
            tsv.flush()
            print(
                f"r{r} +{dt}ms find={int(fh)} login={int(lh)} ck={ck} {' '.join(ev)}",
                flush=True,
            )
            time.sleep(0.18)

        # 回合结论
        line = (
            f"ROUND_{r}_SUMMARY find_ms={t_find} login_ms={t_login} "
            f"order={'find→login' if (t_find is not None and t_login is not None and t_find <= t_login) else 'other'} "
            f"saw_find={saw_find} saw_login={saw_login}"
        )
        print(line, flush=True)
        open(os.path.join(OUT, "round_summary.txt"), "a").write(line + "\n")

        # 下一轮前若已在登录则直接进；否则再等
        time.sleep(0.5)

    tsv.close()

    # 写对比骨架
    md = os.path.join(OUT, "STEP_COMPARE.md")
    summ = open(os.path.join(OUT, "round_summary.txt")).read() if os.path.exists(
        os.path.join(OUT, "round_summary.txt")
    ) else "(empty)"
    open(md, "w").write(
        f"""# .171 触动分步观察 · {STAMP}

## 观察步骤（每轮）
1. **登录色可见**（ROI {LOGIN_XY} ≈ {LOGIN_RGB}）→ 记 baseline
2. **`ziyan_minall`**（SBSSuspendFrontmost）→ T=0
3. 之后 {after_s:.0f}s 内每 ~180ms 抓 TS `/snapshot1`，判：
   - **A 找色点** {FIND_XY} ≈ {FIND_RGB}（脚本命中后会 touchDown/Up）
   - **B 登录色** {LOGIN_XY} ≈ {LOGIN_RGB}（toast「登录」对应屏上色）
4. 记录 cksum 变化、TSDaemon CPU、FIND_FIRST / LOGIN_FIRST 时刻

## 本轮摘要
```
{summ}
```

## 读 timeline.tsv 的方式
- `pre`：min 前，期望 `login=1`，`find` 可 0/1
- `min`：T=0
- `post`：min 后
  - 若 **find 先于 login** 且 find 出现时 login 曾为 0 → 触动在「非登录页/桌面过渡」仍能扫到找色点并点击回游
  - 若 **login 几乎不掉** → 挂起未真正离开登录 UI（或截图像素仍是游戏）
  - **ck_chg** 密集 → 同一缓冲持续灌新像素（对齐既有 IOSurface 结论）

## 对照子砚（待填）
| 步骤 | 触动 .171 | 子砚 |
|------|-----------|------|
| min 手段 | SBSSuspend | .ziyan_go_home + suspend_bid |
| min 后缓冲 | 见 cksum/CPU | retain_app_frame / SB 盖帧 |
| SB/过渡找色 | FIND_FIRST 时刻 | searching + miss |
| 点击回前台 | FIND 后 front 回游戏 | need_game 等 front |
| 再出登录 | LOGIN_FIRST | toast 登录 |

证据：`{OUT}`
"""
    )
    print("VERDICT", md, flush=True)
    # 快捷拷贝
    open(os.path.join(ROOT, "tmp_shots", "TS171_STEP_LATEST.md"), "w").write(
        open(md).read()
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
