#!/usr/bin/env python3
"""Offline P2 A/B/C contract fixture. No device writes. No user scripts."""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def fnv1a32(s: str) -> str:
    h = 2166136261
    for ch in s.encode("utf-8"):
        h ^= ch
        h = (h * 16777619) & 0xFFFFFFFF
    return f"{h:08x}"


def stamp(d: dict) -> dict:
    out = dict(d)
    out["schema_version"] = 1
    out["created_at"] = int(time.time() * 1000)
    body = json.dumps(out, ensure_ascii=False, separators=(",", ":"))
    out["hash"] = fnv1a32(body)
    return out


def is_user_handwritten(path: str) -> bool:
    base = os.path.basename(path)
    if "_学习草稿" in base or "_自研草稿" in base:
        return False
    return True


def after_valid(obs: dict) -> tuple[bool, str]:
    after = obs.get("after_features")
    if not isinstance(after, dict):
        return False, "after_frame_missing"
    b = int(obs.get("frame_seq_before") or 0)
    a = int(obs.get("frame_seq_after") or 0)
    if a <= b or not after.get("changed"):
        return False, "after_frame_missing"
    return True, ""


def critic_allow(obs: dict) -> tuple[bool, str]:
    if obs.get("source") not in ("contract_fixture", "synthetic_test", "user_input"):
        return False, "insufficient_observation"
    if obs.get("sensitive_flag"):
        return False, "insufficient_observation"
    if not obs.get("bundle_id"):
        return False, "insufficient_observation"
    np = obs.get("normalized_point") or {}
    if not isinstance(np, dict) or "x" not in np or "y" not in np:
        return False, "insufficient_observation"
    ok, why = after_valid(obs)
    if not ok:
        return False, why
    return True, "qualified_observation"


def render_lua(obs: dict, plan: dict) -> str:
    bid = obs["bundle_id"]
    nx = float(obs["normalized_point"]["x"])
    ny = float(obs["normalized_point"]["y"])
    ax = float(obs["anchor"]["x"])
    ay = float(obs["anchor"]["y"])
    roi = obs["roi"]
    timeout = int(plan["timeout"])
    retry = int(plan["max_retry"])
    sid = obs["session_id"]
    return f"""-- 学习草稿 · 需要验证
-- schema_version=1 session={sid} game=simNote
-- source=contract_fixture not_user_game=1 not_production_rule=1
-- 相对归一化坐标 / anchor / ROI；禁止当作稳定版本
init(1)
local TARGET='{bid}'
local NX,NY={nx:.4f},{ny:.4f}
local AX,AY={ax:.4f},{ay:.4f}
local ROI={{x1={float(roi['x1']):.4f},y1={float(roi['y1']):.4f},x2={float(roi['x2']):.4f},y2={float(roi['y2']):.4f}}}
local TIMEOUT_MS={timeout}
local MAX_RETRY={retry}
local PRECONDITION='front=={bid}'
local POSTCONDITION='front_ok_or_UNKNOWN'
local function var_dir()
  if type(ZIYAN_VAR)=='string' and #ZIYAN_VAR>0 then return ZIYAN_VAR end
  if io.open('/var/jb/usr/lib/ziyan/var','r') then return '/var/jb/usr/lib/ziyan/var' end
  return '/usr/lib/ziyan/var'
end
local function stopped()
  local f=io.open(var_dir()..'/.ziyan_stop','r')
  if f then f:close(); return true end
  f=io.open(var_dir()..'/.ziyan_user_stopped','r')
  if f then f:close(); return true end
  return false
end
local function front_ok()
  if type(frontAppBid)~='function' then return false end
  return tostring(frontAppBid() or '')==TARGET
end
if stopped() or not front_ok() then
  if type(toast)=='function' then toast('PAUSED_SAFE') end
  return
end
local w,h=0,0
if type(getScreenSize)=='function' then w,h=getScreenSize() end
if not w or w<1 then w,h=375,667 end
local x,y=NX*w,NY*h
local n=0
while n<=MAX_RETRY do
  if stopped() or not front_ok() then
    if type(toast)=='function' then toast('UNKNOWN') end
    break
  end
  tap(x,y)
  if type(mSleep)=='function' then mSleep(TIMEOUT_MS) end
  if front_ok() then break end
  n=n+1
end
"""


def main() -> int:
    stamp_dir = os.environ.get("ZY_P2_OUT")
    if not stamp_dir:
        stamp_dir = str(
            ROOT
            / "tmp_shots"
            / f"AGENT_P2_CONTRACT_FIXTURE_{time.strftime('%Y%m%d_%H%M%S')}"
        )
    out = Path(stamp_dir)
    out.mkdir(parents=True, exist_ok=True)

    sid = "ags_contract_fixture_p2"
    allow_obs = stamp(
        {
            "session_id": sid,
            "event_id": "ev_fixture_1",
            "source": "contract_fixture",
            "not_user_game": 1,
            "not_production_rule": 1,
            "bundle_id": "com.ownbook.notes",
            "front_bid": "com.ownbook.notes",
            "source_session": sid,
            "device_profile": "offline_contract_iphone_logical",
            "orientation": 0,
            "normalized_point": {"x": 0.3200, "y": 0.4100},
            "logical_point": {"x": 120.0, "y": 240.0},
            "anchor": {"x": 0.3200, "y": 0.4100, "name": "notes_safe_center"},
            "roi": {"x1": 0.20, "y1": 0.30, "x2": 0.45, "y2": 0.55},
            "frame_seq_before": 100,
            "frame_seq_after": 104,
            "before_features": {"seq": 100, "front": "com.ownbook.notes"},
            "after_features": {
                "seq": 104,
                "changed": True,
                "timed_out": False,
            },
            "precondition": "front==com.ownbook.notes",
            "postcondition": "front_ok_or_UNKNOWN",
            "timeout": 800,
            "max_retry": 1,
            "risk": "low",
            "idempotent": 1,
            "confidence": 0.7,
            "sensitive_flag": 0,
            "timestamp": int(time.time() * 1000),
            "action_type": "tap",
        }
    )
    ok, reason = critic_allow(allow_obs)
    if not ok:
        print("ALLOW_FIXTURE_CRITIC_FAIL", reason)
        return 2

    plan = stamp(
        {
            "session_id": sid,
            "source_session": sid,
            "source_observations": [allow_obs["event_id"]],
            "game_name": "simNote",
            "bundle_id": "com.ownbook.notes",
            "actions": ["tap_normalized"],
            "precondition": "front==com.ownbook.notes",
            "postcondition": "front_ok_or_UNKNOWN",
            "timeout": 800,
            "max_retry": 1,
            "risk": "low",
            "idempotent": 1,
            "not_user_game": 1,
            "not_production_rule": 1,
            "source": "contract_fixture",
            "generated_lua_path": "SimNote_学习草稿.lua",
            "device_profile": "offline_contract_iphone_logical",
        }
    )
    lua = render_lua(allow_obs, plan)
    raw_abs = ("tap(120" in lua) or ("while true" in lua)
    contract = (
        "frontAppBid" in lua
        and "stopped" in lua
        and "NX,NY" in lua
        and "ROI" in lua
        and "AX,AY" in lua
        and "PRECONDITION" in lua
        and "POSTCONDITION" in lua
        and "TIMEOUT_MS" in lua
        and "MAX_RETRY" in lua
        and not raw_abs
    )
    if not contract:
        print("ALLOW_LUA_CONTRACT_FAIL")
        return 3

    verdict_allow = stamp(
        {
            "session_id": sid,
            "subject_hash": fnv1a32(lua),
            "decision": "ALLOW",
            "reason": reason,
            "evidence_refs": ["observation_allow.json"],
            "quality_score": 0.72,
            "performance_summary": {"observations": 1, "allowed": 1},
            "next_action": "verify_draft",
            "source": "contract_fixture",
            "not_user_game": 1,
            "not_production_rule": 1,
        }
    )
    meta = {
        "kind": "学习草稿",
        "session": sid,
        "game": "simNote",
        "bundle_id": "com.ownbook.notes",
        "need_verify": True,
        "normalized": True,
        "user_overwrite": False,
        "source": "contract_fixture",
        "not_user_game": 1,
        "not_production_rule": 1,
        "copy_on_write": True,
        "written_to_device_media": False,
    }
    quality = {
        "session": sid,
        "decision": "ALLOW",
        "events": 1,
        "lua_written": True,
        "user_overwrite": False,
        "source": "contract_fixture",
    }

    reject_obs = stamp(
        {
            "session_id": "ags_contract_reject_p2",
            "event_id": "ev_fixture_reject",
            "source": "contract_fixture",
            "not_user_game": 1,
            "not_production_rule": 1,
            "bundle_id": "com.ownbook.notes",
            "front_bid": "com.ownbook.notes",
            "source_session": "ags_contract_reject_p2",
            "device_profile": "offline_contract_iphone_logical",
            "normalized_point": {"x": 0.32, "y": 0.41},
            "anchor": {"x": 0.32, "y": 0.41, "name": "notes_safe_center"},
            "roi": {"x1": 0.2, "y1": 0.3, "x2": 0.45, "y2": 0.55},
            "frame_seq_before": 100,
            "frame_seq_after": 100,
            "before_features": {"seq": 100, "front": "com.ownbook.notes"},
            "after_features": {"seq": 100, "changed": False, "timed_out": True},
            "timeout": 800,
            "max_retry": 1,
            "risk": "low",
            "idempotent": 1,
            "sensitive_flag": 0,
        }
    )
    rok, rreason = critic_allow(reject_obs)
    if rok or rreason != "after_frame_missing":
        print("REJECT_FIXTURE_CRITIC_FAIL", rok, rreason)
        return 4
    verdict_reject = stamp(
        {
            "session_id": "ags_contract_reject_p2",
            "subject_hash": fnv1a32(""),
            "decision": "REJECT",
            "reason": rreason,
            "evidence_refs": ["rejected_observation.json"],
            "quality_score": 0.1,
            "performance_summary": {"observations": 1, "allowed": 0},
            "next_action": "manual_review",
            "generated_lua_path": "",
            "source": "contract_fixture",
        }
    )

    cow = {
        "would_write_user_ios8p": is_user_handwritten(
            "/private/var/mobile/Media/ZiYan/ios8p.lua"
        ),
        "would_write_user_ios7": is_user_handwritten(
            "/private/var/mobile/Media/ZiYan/lua/ios7.lua"
        ),
        "would_write_learn_draft": is_user_handwritten(
            str(out / "SimNote_学习草稿.lua")
        ),
        "device_media_write": False,
        "auto_run": False,
    }
    if cow["would_write_user_ios8p"] is not True or cow["would_write_learn_draft"] is not False:
        print("COW_RULE_FAIL", cow)
        return 5

    (out / "observation_allow.json").write_text(
        json.dumps(allow_obs, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (out / "plan_allow.json").write_text(
        json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (out / "verdict_allow.json").write_text(
        json.dumps(verdict_allow, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (out / "generated_lua.txt").write_text(lua, encoding="utf-8")
    (out / "SimNote_学习草稿.lua").write_text(lua, encoding="utf-8")
    (out / "generated_meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (out / "rejected_observation.json").write_text(
        json.dumps(reject_obs, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (out / "verdict_reject.json").write_text(
        json.dumps(verdict_reject, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (out / "quality_report.json").write_text(
        json.dumps(quality, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (out / "copy_on_write.json").write_text(
        json.dumps(cow, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print("OUT=" + str(out))
    print("P2_CONTRACT_ALLOW=PASS")
    print("P2_CONTRACT_REJECT=PASS")
    print("NO_USER_SCRIPT_OVERWRITE=PASS")
    print("NO_RAW_ABSOLUTE_TAP_LOOP=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
