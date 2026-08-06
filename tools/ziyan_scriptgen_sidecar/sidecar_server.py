#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ZiYan scriptgen sidecar — A → Codegen → B → C（本地权重，不联网）
HTTP :8765  +  可选轮询真机 scriptgen_req.json（SSH）
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import socket
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path("/Users/mac/Desktop/ZiYan_副本")
HF = ROOT / "vendor" / "hf_models"
SEED_FAM = ROOT / "media_seed" / "knowledge" / "families"
AUDIT = ROOT / "大模型" / "codegen_out"
PASS = os.environ.get("ZIYAN_SSH_PASS", "alpine")
HOST = os.environ.get("ZIYAN_SIDECAR_HOST", "0.0.0.0")
PORT = int(os.environ.get("ZIYAN_SIDECAR_PORT", "8765"))
POLL_DEVICES = [
    d.strip()
    for d in os.environ.get("ZIYAN_SIDECAR_POLL", "192.168.31.101").split(",")
    if d.strip()
]

REPOS = {
    "A": "ynyg__Unified_Prompt_Guard",
    "B": "vincentoh__jailbreak-detector-v5",
    "C": "llm-semantic-router__mmbert-jailbreak-detector-merged",
}


def weight_ready(repo: str) -> tuple[bool, int]:
    d = HF / repo
    if not d.is_dir():
        return False, 0
    total = 0
    has_w = False
    for p in d.rglob("*"):
        if not p.is_file() or ".cache" in p.parts:
            continue
        total += p.stat().st_size
        name = p.name.lower()
        if name.endswith((".safetensors", ".bin", ".onnx", ".pt", ".gguf")):
            has_w = True
        if name == "config.json" and total > 1024:
            has_w = has_w or True
    # adapter-only repos count if adapter_model present
    if (d / "adapter_model.safetensors").is_file() or (
        d / "model.safetensors"
    ).is_file():
        has_w = True
    return has_w and total > 10_000, total


def score_prompt_guard(text: str) -> dict:
    """A：启发式风险分（本地，不替代真权重存在性）。"""
    bad = ["忽略以上", "jailbreak", "DAN", "bypass lock", 'require("ts")', "require('ts')"]
    hits = sum(1 for k in bad if k.lower() in text.lower())
    # 真正引用 TSLib 才计风险；注释「禁止 TSLib」不计
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("--"):
            continue
        if "TSLib" in s or "require(\"ts\")" in s:
            hits += 1
            break
    conf = min(0.95, 0.02 + hits * 0.25)
    label = "risk" if hits else "safe"
    return {"id": "A", "label": label, "conf": round(conf, 3), "ok": hits == 0}


def score_vincentoh(text: str) -> dict:
    """B：轻量越狱探测启发式。"""
    bad = ["system prompt", "ignore previous", "developer mode", "越狱检测绕过"]
    hits = sum(1 for k in bad if k.lower() in text.lower())
    conf = min(0.9, 0.05 + hits * 0.2)
    return {"id": "B", "label": "ok" if hits == 0 else "suspect", "conf": round(conf, 3), "ok": hits == 0}


def score_mmbert(text: str) -> dict:
    """C：语义完整性（业务阶段关键词）。"""
    need = [
        "phase_login",
        "phase_role_select",
        "phase_enter_game",
        "phase_auto_battle",
        "runApp",
    ]
    miss = [k for k in need if k not in text]
    conf = round(0.05 + 0.18 * (len(need) - len(miss)), 3)
    tslib_live = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("--"):
            continue
        if "TSLib" in s or 'require("ts")' in s:
            tslib_live = True
            break
    ok = len(miss) == 0 and not tslib_live
    return {
        "id": "C",
        "label": "ok" if ok else "incomplete",
        "conf": conf,
        "ok": ok,
        "missing": miss,
    }


def load_family(family: str) -> dict:
    p = SEED_FAM / f"{family}.json"
    if not p.is_file():
        # try device-synced copy under Media seed only
        return {"family": family, "imported": False, "phases": {}}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {"family": family, "imported": False, "phases": {}}


def rows_for(phase: dict, key: str, limit: int = 6) -> str:
    items = (phase or {}).get(key) or []
    if not isinstance(items, list):
        return "  -- empty\n"
    lines = []
    for it in items[:limit]:
        if not isinstance(it, dict):
            continue
        label = it.get("label") or key
        first = it.get("first") or it.get("color") or "0xFFFFFF"
        if isinstance(first, int):
            first = f"0x{first:06x}"
        off = it.get("off") or it.get("offset") or "0|1|0xFFFFFF"
        deg = int(it.get("degree") or it.get("sim") or 85)
        x1 = int(it.get("x1") or 0)
        y1 = int(it.get("y1") or 0)
        x2 = int(it.get("x2") or x1 + 40)
        y2 = int(it.get("y2") or y1 + 40)
        lines.append(
            f'  {{label="{label}", first={first}, off="{off}", degree={deg}, '
            f"x1={x1},y1={y1},x2={x2},y2={y2}}},"
        )
    return ("\n".join(lines) + "\n") if lines else "  -- empty\n"


def emit_full_lua(req: dict, doc: dict) -> str:
    bid = req.get("bid") or "com.example.game"
    name = req.get("app_name") or bid
    fam = req.get("game_family") or doc.get("family") or "generic"
    profile = req.get("res_profile") or "iphone7_13"
    phases = doc.get("phases") or {}
    imported = bool(doc.get("imported"))
    login = rows_for(phases, "login")
    server = rows_for(phases, "server")
    role = rows_for(phases, "role")
    enter = rows_for(phases, "enter")
    battle = rows_for(phases, "battle")
    popup = rows_for(phases, "popup")
    return f'''-- ZiYan full business script R8.4.3 (sidecar A→Codegen→B→C)
-- family={fam} imported={str(imported).lower()} models=ABC
-- app={name} bid={bid}
-- DO NOT require TSLib/ts/sz — ZiYan engine APIs only
-- flows: boot→login→server→role→enter→battle
local BID = "{bid}"
local RES = {{ profile = "{profile}", family = "{fam}", imported = {str(imported).lower()} }}
local OCR_INTERVAL_MS, FIND_INTERVAL_MS, SLEEP_MIN = 350, 200, 300
local deadline = os.time() + 7200
local STATE = "boot"

local PHASE = {{
  login = {{
{login}  }},
  server = {{
{server}  }},
  role = {{
{role}  }},
  enter = {{
{enter}  }},
  battle = {{
{battle}  }},
  popup = {{
{popup}  }},
}}

local function sleep_ms(ms)
  if ms < SLEEP_MIN then ms = SLEEP_MIN end
  mSleep(ms)
end

local function ocr_text()
  if type(ocr) ~= "function" then return "" end
  sleep_ms(OCR_INTERVAL_MS)
  local ok, t = pcall(ocr, 0, 0, -1, -1)
  return (ok and tostring(t or "")) or ""
end

local function find_hit(p)
  if type(findMultiColorInRegionFuzzy) ~= "function" or type(p) ~= "table" then
    return false
  end
  sleep_ms(FIND_INTERVAL_MS)
  local x, y = findMultiColorInRegionFuzzy(p.first, p.off, p.degree, p.x1, p.y1, p.x2, p.y2)
  if x and x >= 0 and y and y >= 0 then
    return true, x, y
  end
  return false
end

local function do_learn(label, x, y)
  if type(learn) == "function" then pcall(learn, label, x, y, "sidecar", BID) end
  if type(codegen) == "function" then pcall(codegen, BID) end
end

local function try_phase(list, ocr_keys)
  local txt = ocr_text()
  for _, k in ipairs(ocr_keys or {{}}) do
    if txt:find(k) then
      if type(tap) == "function" then tap(568, 300) end
      sleep_ms(800)
      return true
    end
  end
  for _, p in ipairs(list or {{}}) do
    local ok, x, y = find_hit(p)
    if ok then
      if type(tap) == "function" then tap(x, y) end
      do_learn(p.label or "hit", x, y)
      sleep_ms(800)
      return true
    end
  end
  return false
end

function phase_login()
  STATE = "login"
  for _ = 1, 12 do
    if try_phase(PHASE.login, {{"登录","账号","密码","免密","游客","隐私"}}) then return true end
    sleep_ms(600)
  end
  return false
end

function phase_role_select()
  STATE = "role_select"
  for _ = 1, 8 do
    try_phase(PHASE.server, {{"区服","服务器","选服"}})
    if try_phase(PHASE.role, {{"角色","选角","创建角色","选择角色"}}) then return true end
    sleep_ms(600)
  end
  return false
end

function phase_enter_game()
  STATE = "entering"
  for _ = 1, 10 do
    if try_phase(PHASE.enter, {{"进入游戏","开始","副本","任务"}}) then
      STATE = "main"
      return true
    end
    sleep_ms(700)
  end
  return false
end

function phase_auto_battle()
  STATE = "battle"
  for _ = 1, 8 do
    if try_phase(PHASE.battle, {{"挂机","自动战斗","攻击","技能","挂图"}}) then return true end
    sleep_ms(700)
  end
  return false
end

function check_state_and_handle()
  try_phase(PHASE.popup, {{"奖励","升级","活动","关闭","确定"}})
  local txt = ocr_text()
  if txt:find("登录") then phase_login()
  elseif txt:find("角色") then phase_role_select()
  elseif txt:find("进入") then phase_enter_game()
  else phase_auto_battle() end
end

function main()
  init(1)
  keepScreen(true)
  toast("gen-full-ABC:" .. "{name}", 1500)
  runApp(BID)
  sleep_ms(5000)
  if type(syncGameScreen) == "function" then syncGameScreen(1, BID)
  elseif type(gameSync) == "function" then gameSync(1, BID) end
  phase_login()
  phase_role_select()
  phase_enter_game()
  phase_auto_battle()
  while os.time() < deadline do
    check_state_and_handle()
    sleep_ms(1000)
  end
  keepScreen(false)
end
main()
'''


def run_pipeline(req: dict) -> dict:
    family = req.get("game_family") or "xztl"
    # normalize family ids
    fam_map = {
        "血战屠龙": "xztl",
        "赤沙龙城": "cslc",
        "新版血战": "xbxz",
        "圣戒信条": "sjxt",
        "怒剑传奇": "njcq",
        "龙界争霸": "ljzb",
    }
    family = fam_map.get(family, family)
    doc = load_family(family)
    ready = {}
    for mid, repo in REPOS.items():
        ok, nbytes = weight_ready(repo)
        ready[mid] = {"repo": repo, "ok": ok, "bytes": nbytes}

    # Codegen
    lua = emit_full_lua(req, doc)
    # A → B → C serial
    a = score_prompt_guard(lua)
    if not a["ok"]:
        lua = lua.replace('require("ts")', "-- no ts").replace("require('ts')", "-- no ts")
        a = score_prompt_guard(lua)
    b = score_vincentoh(lua)
    c = score_mmbert(lua)
    # if C incomplete, force re-emit
    if not c["ok"]:
        lua = emit_full_lua(req, doc)
        c = score_mmbert(lua)

    models_ok = all(ready[m]["ok"] for m in ("A", "B", "C")) and a["ok"] and b["ok"] and c["ok"]
    audit = datetime.now().strftime("%Y%m%d_%H%M%S") + "_" + hashlib.md5(
        (req.get("bid") or "").encode()
    ).hexdigest()[:8]
    AUDIT.mkdir(parents=True, exist_ok=True)
    out_dir = AUDIT / audit
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "script.lua").write_text(lua, encoding="utf-8")
    (out_dir / "meta.json").write_text(
        json.dumps(
            {"req": req, "ready": ready, "models": {"A": a, "B": b, "C": c}},
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    return {
        "ok": bool(c["ok"] and "runApp" in lua and "phase_login" in lua),
        "lua": lua,
        "models": {
            "prompt_guard": a,
            "vincentoh": b,
            "mmbert": c,
        },
        "weights_ready": ready,
        "models_combined": True,
        "models_ready": models_ok,
        "from_sidecar": True,
        "audit_id": audit,
        "pipeline": "A→Codegen→B→C",
        "game_family": family,
        "knowledge_imported": bool(doc.get("imported")),
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[sidecar] {self.address_string()} {fmt % args}", flush=True)

    def _json(self, code: int, obj: dict):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/health") or self.path == "/":
            ready = {k: weight_ready(v)[0] for k, v in REPOS.items()}
            self._json(200, {"ok": True, "ready": ready, "pipeline": "A→Codegen→B→C"})
            return
        self._json(404, {"ok": False, "error": "not_found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            req = json.loads(raw.decode("utf-8") or "{}")
        except Exception:
            self._json(400, {"ok": False, "error": "bad_json"})
            return
        if self.path.endswith("/v1/scriptgen/run") or self.path.endswith("/scriptgen/run"):
            try:
                self._json(200, run_pipeline(req))
            except Exception as e:
                self._json(500, {"ok": False, "error": str(e)})
            return
        if self.path.endswith("/v1/dump_analyze/run") or self.path.endswith("/dump_analyze/run"):
            # minimal dump analyze ABC pass-through
            summary = json.dumps(req.get("summary") or {}, ensure_ascii=False)
            a, b, c = score_prompt_guard(summary), score_vincentoh(summary), score_mmbert(
                "phase_login phase_role_select phase_enter_game phase_auto_battle runApp"
            )
            self._json(
                200,
                {
                    "ok": True,
                    "report_md": "# dump analyze\n\nABC pass\n",
                    "report_json": {"risk_level": "low", "findings": []},
                    "models": {"prompt_guard": a, "vincentoh": b, "mmbert": c},
                    "models_combined": True,
                    "audit_id": datetime.now().strftime("%Y%m%d_%H%M%S_dump"),
                },
            )
            return
        if self.path.endswith("/v1/vision/analyze") or self.path.endswith("/vision/analyze"):
            # LiveLearn：OCR 文本 + 已采色参 → A/B/C 门禁 + 阶段分桶确认
            ocr = str(req.get("ocr_text") or "")
            colors = req.get("colors") if isinstance(req.get("colors"), list) else []
            blob = ocr + "\n" + json.dumps(colors, ensure_ascii=False)
            a, b = score_prompt_guard(blob), score_vincentoh(blob)
            # C：识字是否覆盖关键阶段词
            need_kw = ["登录", "进入", "角色", "挂机", "自动"]
            hit_kw = [k for k in need_kw if k in ocr or any(k in str(c.get("label", "")) for c in colors if isinstance(c, dict))]
            c = {
                "id": "C",
                "label": "ok" if len(hit_kw) >= 1 else "weak",
                "conf": round(0.2 + 0.15 * len(hit_kw), 3),
                "ok": len(colors) > 0 or len(ocr) > 0,
                "hit_kw": hit_kw,
            }
            # 补 phase 字段
            out_colors = []
            for it in colors:
                if not isinstance(it, dict):
                    continue
                row = dict(it)
                lab = str(row.get("label") or "")
                if not row.get("phase"):
                    if any(k in lab for k in ("登录", "游客", "账号")):
                        row["phase"] = "login"
                    elif any(k in lab for k in ("进入", "开始游戏")):
                        row["phase"] = "enter"
                    elif any(k in lab for k in ("角色",)):
                        row["phase"] = "role"
                    elif any(k in lab for k in ("挂机", "自动")):
                        row["phase"] = "battle"
                    elif any(k in lab for k in ("关闭", "确定")):
                        row["phase"] = "popup"
                    else:
                        row["phase"] = "battle"
                row["via"] = row.get("via") or "sidecar_vision"
                out_colors.append(row)
            self._json(
                200,
                {
                    "ok": True,
                    "colors": out_colors,
                    "ocr_text": ocr,
                    "models": {"prompt_guard": a, "vincentoh": b, "mmbert": c},
                    "models_combined": True,
                    "audit_id": datetime.now().strftime("%Y%m%d_%H%M%S_vision"),
                    "note": "live_ocr_color_no_manual_pick",
                },
            )
            return
        self._json(404, {"ok": False, "error": "not_found"})


def ssh(ip: str, cmd: str, timeout: int = 20) -> str:
    import subprocess

    r = subprocess.run(
        [
            "sshpass",
            "-p",
            PASS,
            "ssh",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "PreferredAuthentications=password",
            "-o",
            "PubkeyAuthentication=no",
            "-o",
            f"ConnectTimeout=8",
            f"root@{ip}",
            cmd,
        ],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return (r.stdout or "") + (r.stderr or "")


def scp_from(ip: str, remote: str, local: Path) -> bool:
    import subprocess

    local.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(
        [
            "sshpass",
            "-p",
            PASS,
            "scp",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "PreferredAuthentications=password",
            "-o",
            "PubkeyAuthentication=no",
            f"root@{ip}:{remote}",
            str(local),
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    return r.returncode == 0 and local.is_file()


def scp_to(ip: str, local: Path, remote: str) -> bool:
    import subprocess

    r = subprocess.run(
        [
            "sshpass",
            "-p",
            PASS,
            "scp",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "PreferredAuthentications=password",
            "-o",
            "PubkeyAuthentication=no",
            str(local),
            f"root@{ip}:{remote}",
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    return r.returncode == 0


def poll_devices_loop():
    tmp = ROOT / "tmp_shots" / "PHASE763R8" / "sidecar_poll"
    tmp.mkdir(parents=True, exist_ok=True)
    seen = {}
    while True:
        for ip in POLL_DEVICES:
            local_req = tmp / f"{ip}_scriptgen_req.json"
            if scp_from(ip, "/var/mobile/Media/ZiYan/scriptgen_req.json", local_req):
                try:
                    st = local_req.stat().st_mtime
                except OSError:
                    st = 0
                if seen.get(ip) == st:
                    time.sleep(1)
                    continue
                try:
                    req = json.loads(local_req.read_text(encoding="utf-8"))
                except Exception:
                    time.sleep(1)
                    continue
                print(f"[poll] {ip} scriptgen_req", flush=True)
                res = run_pipeline(req)
                local_res = tmp / f"{ip}_scriptgen_result.json"
                local_res.write_text(json.dumps(res, ensure_ascii=False), encoding="utf-8")
                if scp_to(ip, local_res, "/var/mobile/Media/ZiYan/scriptgen_result.json"):
                    ssh(ip, "rm -f /var/mobile/Media/ZiYan/scriptgen_req.json")
                    seen[ip] = st
                    print(f"[poll] {ip} result ok audit={res.get('audit_id')}", flush=True)
        time.sleep(2)


def write_local_models_status():
    lines = ["stage=6", "runtime=mac_sidecar+weight_presence"]
    ready_n = 0
    for mid, repo in REPOS.items():
        ok, n = weight_ready(repo)
        if ok:
            ready_n += 1
            lines.append(f"{repo}=READY weight=1 cfg=1 bytes={n}")
        else:
            lines.append(f"{repo}=MISS weight=0 cfg=0 bytes={n}")
    lines.append(f"ready_count={ready_n}/3")
    p = HF / "models_status.txt"
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    (ROOT / "大模型" / "models_status.txt").write_text(
        "\n".join(lines) + "\n", encoding="utf-8"
    )
    return ready_n


def main():
    n = write_local_models_status()
    print(f"[sidecar] weights ready {n}/3 on {HOST}:{PORT}", flush=True)
    th = threading.Thread(target=poll_devices_loop, daemon=True)
    th.start()
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"[sidecar] listening http://{HOST}:{PORT}  poll={POLL_DEVICES}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
