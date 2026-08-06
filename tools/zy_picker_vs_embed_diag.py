#!/usr/bin/env python3
# 抓色器对照：Desktop≡formats ↔ /findtest+/biztest ↔ 机上 IPC findMulti
# 禁改色参；禁用触动色参。用法：python3 tools/zy_picker_vs_embed_diag.py
from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "tmp_shots" / f"PICKER_VS_EMBED_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
PASS = os.environ.get("ZY_SSH_PASS", "alpine")
DESKTOP = {
    "ios8p": [
        ("f1", "0xfdffed", "-3|3|0xf3f3ca,-1|4|0xfffff7,2|8|0x410703", 2010, 279, 2015, 287),
        ("f2", "0xc6a264", "2|4|0xc6a264,2|7|0xc6a264,2|10|0xc6a264", 757, 788, 759, 798),
    ],
    "ios7": [
        ("f1", "0xc68c1a", "1|1|0xc48d12,2|1|0xd29829,2|4|0x7b492c", 1008, 306, 1010, 310),
        ("f2", "0xc19b67", "1|2|0xb68b50,1|4|0xd3b281,0|5|0xd8b788", 706, 449, 707, 454),
    ],
}
PHONES = [
    ("53", "192.168.31.53", "rootless", "com.ljzbbadao.game", "ios8p"),
    ("101", "192.168.31.101", "rootful", "com.xztl.ios", "ios7"),
    ("112", "192.168.31.112", "rootful", "com.xztl.ios", "ios7"),
    ("166", "192.168.31.166", "rootful", "com.xztl.ios", "ios7"),
]

lines: list[str] = []


def note(s: str) -> None:
    print(s, flush=True)
    lines.append(s)


def ssh(ip: str, script: str, timeout: int = 60) -> str:
    cmd = [
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
        f"root@{ip}",
        "bash -s",
    ]
    r = subprocess.run(cmd, input=script, capture_output=True, text=True, timeout=timeout)
    return (r.stdout or "") + (("\n" + r.stderr) if r.stderr else "")


def http_get(url: str, timeout: float = 8.0) -> tuple[int, bytes]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.status, resp.read()
    except Exception as e:
        return 0, str(e).encode()


def http_post(url: str, data: dict, timeout: float = 25.0) -> dict:
    body = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            return json.loads(raw)
    except Exception as e:
        return {"ok": False, "error": str(e)}


def var_bin(scheme: str) -> tuple[str, str]:
    if scheme == "rootless":
        return "/var/jb/usr/lib/ziyan/var", "/var/jb/usr/lib/ziyan/bin"
    return "/usr/lib/ziyan/var", "/usr/lib/ziyan/bin"


def pts_json(main: str, offs: str) -> str:
    # 与抓色器 FlatPointsJSON / ColorMatch 一致：b=0（0xRRGGBB 偏色；禁填 25 当通道容差）
    m = int(main, 16)
    pts = [{"c": m, "dx": 0, "dy": 0, "b": 0}]
    if offs:
        for part in offs.split(","):
            dx, dy, col = part.split("|")
            pts.append({"c": int(col, 16), "dx": int(dx), "dy": int(dy), "b": 0})
    return json.dumps(pts, separators=(",", ":"))


def ensure_http(ip: str, scheme: str) -> bool:
    code, _ = http_get(f"http://{ip}:50005/status", 4)
    if code == 200:
        return True
    var, binp = var_bin(scheme)
    ssh(
        ip,
        f"killall -9 ziyan_framecap 2>/dev/null; sleep 1; "
        f"nohup {binp}/ziyan_framecap serve >/dev/null 2>&1 & sleep 2; true",
    )
    for _ in range(4):
        code, _ = http_get(f"http://{ip}:50005/status", 4)
        if code == 200:
            return True
        time.sleep(1.5)
    return False


def warm_game(ip: str, scheme: str, bid: str) -> str:
    var, binp = var_bin(scheme)
    return ssh(
        ip,
        f"""
set +e
VAR={var}; BIN={binp}; BID={bid}
echo 1 >"$VAR/.ziyan_unlock_req"; sleep 0.4
for i in 1 2 3 4 5 6 7 8 9 10; do
  printf '%s\\n' "$BID" >"$VAR/.ziyan_open_app"; chmod 666 "$VAR/.ziyan_open_app" 2>/dev/null
  sleep 0.8
  F=$(tr -d '\\r\\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  echo "$F" | grep -q "$BID" && break
done
rm -f "$VAR/.ziyan_open_app"
for i in 1 2 3 4 5 6; do
  echo 1 >"$VAR/.ziyan_force_recap"
  echo "nonce=warm_$i" >"$VAR/.ziyan_frame_req"
  "$BIN/ziyan_framecap" once >/dev/null 2>&1 || true
  sleep 1
  SHM=$(tr -d '\\r\\n' <"$VAR/.ziyan_shm_front_bid" 2>/dev/null)
  F=$(tr -d '\\r\\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
  echo "WARM_$i FRONT=$F SHM=$SHM"
  echo "$SHM" | grep -q "$BID" && exit 0
done
exit 1
""",
        timeout=90,
    )


def ipc_find(ip: str, scheme: str, name: str, main: str, offs: str, x1: int, y1: int, x2: int, y2: int) -> str:
    var, binp = var_bin(scheme)
    pts = pts_json(main, offs)
    b64 = base64.b64encode(pts.encode()).decode()
    return ssh(
        ip,
        f"""
set +e
VAR={var}; BIN={binp}; NAME={name}; X1={x1}; Y1={y1}; X2={x2}; Y2={y2}
PTS=$(printf '%s' '{b64}' | base64 -d 2>/dev/null || printf '%s' '{b64}' | base64 -D)
echo 1 >"$VAR/.ziyan_force_recap"
echo "nonce=ipc_$NAME" >"$VAR/.ziyan_frame_req"
"$BIN/ziyan_framecap" once >/dev/null 2>&1 || true
sleep 1
rm -f "$VAR/.ziyan_color_rep"
printf 'findMulti\\n%s\\n90\\n%s\\n%s\\n%s\\n%s\\n%s\\n' "$PTS" "$X1" "$Y1" "$X2" "$Y2" "$NAME" >"$VAR/.ziyan_color_req"
for i in $(seq 1 50); do sleep 0.05; [ -f "$VAR/.ziyan_color_rep" ] && break; done
echo REP=$(tr '\\n' ' ' <"$VAR/.ziyan_color_rep" 2>/dev/null)
echo FRONT=$(tr -d '\\r\\n' <"$VAR/.ziyan_front_bid" 2>/dev/null)
echo SHM=$(tr -d '\\r\\n' <"$VAR/.ziyan_shm_front_bid" 2>/dev/null)
CX=$(( (X1+X2)/2 )); CY=$(( (Y1+Y2)/2 ))
rm -f "$VAR/.ziyan_color_rep"
printf 'getColor\\n%s\\n%s\\ngc\\n' "$CX" "$CY" >"$VAR/.ziyan_color_req"
for i in $(seq 1 40); do sleep 0.05; [ -f "$VAR/.ziyan_color_rep" ] && break; done
echo GC=$(tr '\\n' ' ' <"$VAR/.ziyan_color_rep" 2>/dev/null)
""",
        timeout=60,
    )


def offline_check() -> None:
    note("==== offline ColorPicker + formats≡Desktop ====")
    r = subprocess.run(
        [sys.executable, str(ROOT / "tools/ziyan_colorpicker/ZiYanColorPicker.py"), "--test"],
        capture_output=True,
        text=True,
    )
    note("PASS ColorPicker --test" if r.returncode == 0 else f"FAIL ColorPicker --test {r.stderr[:200]}")
    sys.path.insert(0, str(ROOT / "tools/ziyan_colorpicker"))
    import formats  # type: ignore

    fail = 0
    for path, tag in [
        (Path("/Users/mac/Desktop/ios7.lua"), "ios7"),
        (Path("/Users/mac/Desktop/ios8p.lua"), "ios8p"),
    ]:
        for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if "findMultiColorInRegionFuzzy" not in line:
                continue
            mm = re.search(
                r'findMultiColorInRegionFuzzy\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]*)"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)',
                line,
            )
            if not mm:
                note(f"FAIL parse {tag} L{i}")
                fail += 1
                continue
            main, offs = mm.group(1).lower(), mm.group(2)
            pts = [{"x": 0, "y": 0, "c": int(main, 16)}]
            if offs:
                for part in offs.split(","):
                    dx, dy, col = part.split("|")
                    pts.append({"x": int(dx), "y": int(dy), "c": int(col, 16)})
            fmc = formats.make_fmc(pts)
            expect = f'{main}, "{offs}"'
            same = fmc.lower() == expect.lower()
            note(f"{'PASS' if same else 'FAIL'} fmc {tag} L{i} SAME={same}")
            if not same:
                fail += 1
    note("PASS formats≡Desktop" if fail == 0 else "FAIL formats≡Desktop")


def cmp_phone(tag: str, ip: str, scheme: str, bid: str, sc: str) -> None:
    note(f"======== .{tag} {sc} {bid} ========")
    http_ok = ensure_http(ip, scheme)
    note(f"HTTP50005 .{tag}={'OK' if http_ok else 'DOWN'}")
    warm = warm_game(ip, scheme, bid)
    (OUT / f"{tag}_warm.txt").write_text(warm, encoding="utf-8")
    note("WARM " + " | ".join([ln for ln in warm.splitlines() if ln.startswith("WARM_")][-3:]))

    if http_ok:
        http_get(f"http://{ip}:50005/snapshot?orient=1", 15)
        bz = http_post(f"http://{ip}:50005/biztest", {"script": sc, "orient": "1"}, 35)
        (OUT / f"{tag}_biz.json").write_text(json.dumps(bz, ensure_ascii=False, indent=2), encoding="utf-8")
        f1 = (bz.get("find1") or {}).get("ok")
        f2 = (bz.get("find2") or {}).get("ok")
        note(f"BIZTEST .{tag} branch={bz.get('branch')} toast_would={bz.get('toast_would')} f1={f1} f2={f2}")
    else:
        note(f"BIZTEST .{tag} SKIP (no HTTP)")

    for name, main, offs, x1, y1, x2, y2 in DESKTOP[sc]:
        note(f"---- .{tag} {name} ----")
        warm_game(ip, scheme, bid)
        ft_ok = None
        if http_ok:
            http_get(f"http://{ip}:50005/snapshot?orient=1", 12)
            ft = http_post(
                f"http://{ip}:50005/findtest",
                {
                    "main": main,
                    "offs": offs,
                    "degree": "90",
                    "x1": str(x1),
                    "y1": str(y1),
                    "x2": str(x2),
                    "y2": str(y2),
                    "toast": "0",
                    "orient": "1",
                },
                20,
            )
            (OUT / f"{tag}_{name}_findtest.json").write_text(
                json.dumps(ft, ensure_ascii=False), encoding="utf-8"
            )
            ft_ok = 1 if ft.get("ok") in (True, 1) else 0
            # 拒假命中：roi 全 0 / x,y=0 且不在原始 ROI
            roi = ft.get("roi") or []
            if ft_ok and roi == [0, 0, 0, 0]:
                note(f"FINDTEST .{tag} {name} SUSPECT_ZERO_ROI {ft}")
                ft_ok = 0
            note(f"FINDTEST .{tag} {name} ok={ft_ok} {json.dumps(ft, ensure_ascii=False)[:220]}")
        else:
            note(f"FINDTEST .{tag} {name} SKIP")

        ipc = ipc_find(ip, scheme, name, main, offs, x1, y1, x2, y2)
        (OUT / f"{tag}_{name}_ipc.txt").write_text(ipc, encoding="utf-8")
        ipc_ok = 1 if '"ok":true' in ipc.replace(" ", "") or '"ok": true' in ipc else 0
        if '"ok":true' in ipc or '"ok": true' in ipc:
            ipc_ok = 1
        else:
            ipc_ok = 0
        note(f"IPC .{tag} {name} ok={ipc_ok} {ipc.replace(chr(10), ' ')[:260]}")

        if ft_ok is None:
            note(f"INFO .{tag} {name} IPC_ONLY ok={ipc_ok}")
        elif ft_ok == ipc_ok:
            note(f"PASS .{tag} {name} findtest≡IPC both={ft_ok}")
        else:
            note(f"FAIL .{tag} {name} findtest={ft_ok} IPC={ipc_ok} DIVERGE")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    note(f"OUT={OUT}")
    offline_check()
    for phone in PHONES:
        try:
            cmp_phone(*phone)
        except Exception as e:
            note(f"FAIL .{phone[0]} exception {e}")

    verd = OUT / "VERDICT.md"
    body = ["# PICKER vs EMBED 对照 VERDICT", "", "- 色参来源：Desktop ≡ 子砚抓色器（未改色参）", ""]
    body.extend(lines)
    body.append("")
    if any("DIVERGE" in x for x in lines):
        body.append("## OVERALL=FAIL_DIVERGE")
        rc = 1
    elif any(x.startswith("FAIL ") for x in lines):
        body.append("## OVERALL=FAIL")
        rc = 1
    else:
        body.append("## OVERALL=AGREE (命中与否另见 BIZTEST/自测；同意指 findtest≡IPC)")
        rc = 0
    verd.write_text("\n".join(body) + "\n", encoding="utf-8")
    (ROOT / "tmp_shots" / "PICKER_VS_EMBED_VERDICT.md").write_text(verd.read_text(encoding="utf-8"), encoding="utf-8")
    note(f"VERDICT -> {verd}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
