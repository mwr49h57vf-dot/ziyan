#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段7.3：为 SDK 目标模块充实完整文档字段（可独立运行，亦被 generate_html 调用）。"""
from __future__ import annotations

import datetime
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = Path(__file__).resolve().parent / "api_catalog.json"
QUALITY = Path(__file__).resolve().parent / "DOC_QUALITY.json"

TARGET = {
    "Device", "Screen", "Coordinate", "Vision", "Image", "OCR", "Touch",
    "File", "Network", "Verify", "StateMachine", "Game", "Script",
    "Config", "Input", "Log", "Optimization", "IssueClassifier",
    "OptimizationAdvisor", "OptimizationRollback",
}

# 关联函数图（同模块/上下游）
RELATED = {
    "Device.refresh": ["Device.profile", "Device.save", "Screen.sync"],
    "Device.profile": ["Device.refresh", "Device.gameRect", "Screen.size"],
    "Device.gameRect": ["Device.profile", "Coordinate.setDesign", "Screen.sync"],
    "Device.unlock": ["Device.refresh", "App.launch"],
    "Screen.sync": ["Device.refresh", "Coordinate.setDesign", "Touch.tapRatio"],
    "Screen.size": ["Screen.info", "Coordinate.ratio"],
    "Screen.snapshot": ["Verify.failReport", "OCR.region", "Image.find"],
    "Screen.keep": ["Image.findColor", "OCR.find"],
    "Coordinate.setDesign": ["Coordinate.point", "Coordinate.ratio", "Script.begin"],
    "Coordinate.point": ["Touch.tapDesign", "Image.colorAtDesign"],
    "Coordinate.ratio": ["Touch.tapRatio", "Touch.swipeRatio"],
    "Vision.analyze": ["OCR.analyze", "Image.findColor", "Touch.tapHit"],
    "Image.findColor": ["Touch.tapHit", "Vision.findColor", "Image.findUntil"],
    "Image.find": ["Touch.tapHit", "Vision.findImage"],
    "OCR.find": ["Touch.tapHit", "OCR.findUntil", "Vision.findText"],
    "Touch.tapRatio": ["Coordinate.ratio", "Verify.act", "Screen.sync"],
    "Touch.tapDesign": ["Coordinate.point", "Verify.act"],
    "Touch.tapHit": ["Vision.analyze", "Image.findColor", "OCR.find"],
    "Touch.swipeRatio": ["Coordinate.ratio", "Touch.gesture"],
    "Verify.act": ["Touch.tapRatio", "Game.phase", "Script.recover"],
    "StateMachine.current": ["Game.phase", "StateMachine.suggest"],
    "Game.analyze": ["Game.phase", "Script.tick", "StateMachine.current"],
    "Script.begin": ["Device.refresh", "Coordinate.setDesign", "Screen.sync", "App.launch"],
    "Script.tick": ["Game.analyze", "Verify.act", "Script.recover"],
    "Config.load": ["Config.save", "Config.get", "Script.set"],
    "Input.text": ["Input.typeAtRatio", "Touch.tapRatio", "App.launch"],
    "Log.write": ["Log.dialog", "Verify.failReport"],
    "Optimization.cycle": ["Optimization.collect", "IssueClassifier.classify", "OptimizationAdvisor.advise", "OptimizationRollback.snapshot"],
    "Optimization.recordHistory": ["Optimization.cycle", "Knowledge.save"],
    "IssueClassifier.classify": ["Optimization.detect", "Optimization.analyze"],
    "OptimizationAdvisor.advise": ["Optimization.propose", "OptimizationAdvisor.confirm"],
    "OptimizationRollback.snapshot": ["OptimizationRollback.restore", "Optimization.apply"],
}

# 完整文档覆盖：key = Zy.Module.fn
DOCS: dict[str, dict] = {}


def D(fq, **kw):
    DOCS[fq] = kw


# ---------- Device ----------
D("Zy.Device.refresh",
  zh_name="刷新", zh_desc="刷新并返回最新设备画像（分辨率、DPI、系统、游戏区等）。",
  purpose="脚本开始或分辨率变化后，必须先刷新设备信息再取色/点击。",
  scenario="启动自动化前；旋转屏幕后；切换应用后重新适配。",
  principle="调用引擎 deviceRefresh/deviceModel，标记管道 Device 已就绪，再返回 profile 表。",
  related=["Zy.Device.profile", "Zy.Screen.sync", "Zy.Script.begin"],
  errors=["底层无 device API 时返回缓存画像或空表"],
  params=[{"name": "无", "type": "—", "desc": "无参数", "required": False, "default": None}],
  returns={"type": "table", "desc": "设备画像：model/os/logic_w/logic_h/dpi/game_rect 等"},
  usage="Zy.Device.refresh()\nDevice.refresh()\n设备.刷新()",
  example="""-- 推荐：脚本开头刷新设备
local prof = Device.refresh()
Log.write("model=" .. tostring(prof and prof.model))
Screen.sync(1)
Coordinate.setDesign(1136, 640)""")

D("Zy.Device.profile",
  zh_name="画像", zh_desc="读取当前已缓存的设备画像，不强制刷新。",
  purpose="快速查询分辨率/机型，避免重复刷新。",
  scenario="日志打印设备信息；按机型选择设计分辨率。",
  principle="读 deviceModel/deviceProfile 或全局 __ZIYAN_DEVICE_PROFILE。",
  related=["Zy.Device.refresh", "Zy.Device.gameRect"],
  errors=["未 refresh 时可能为空"],
  params=[{"name": "无", "type": "—", "desc": "无参数", "required": False, "default": None}],
  returns={"type": "table|nil", "desc": "设备画像表"},
  usage="local p = Device.profile()",
  example="""local p = Device.profile() or Device.refresh()
local w = p.logic_w or select(1, Screen.size())
Log.write("logic=" .. tostring(w))""")

D("Zy.Device.save",
  zh_name="保存", zh_desc="将当前设备画像落盘，供下次快速加载。",
  purpose="跨脚本复用设备识别结果。",
  scenario="首次适配成功后保存；设备库维护。",
  principle="调用 deviceSaveProfile；rootless 可写 Media 下 device_model.json。",
  related=["Zy.Device.refresh", "Zy.Device.profile"],
  errors=["无保存实现时返回 false, reason"],
  params=[{"name": "无", "type": "—", "desc": "无参数", "required": False, "default": None}],
  returns={"type": "boolean [, string]", "desc": "是否保存成功"},
  usage="Device.save()",
  example="Device.refresh()\nlocal ok, err = Device.save()\nif not ok then Log.write(\"save fail:\" .. tostring(err)) end")

D("Zy.Device.gameRect",
  zh_name="游戏区域", zh_desc="返回游戏/内容区矩形（逻辑坐标 x,y,w,h），非整屏物理像素。",
  purpose="裁剪有效触控与找色区域，避开刘海/黑边。",
  scenario="全面屏适配；只在内容区找色。",
  principle="优先 deviceGameRect；否则从 profile.game_rect 读取。",
  related=["Zy.Device.profile", "Zy.Coordinate.region", "Zy.Screen.sync"],
  errors=["未识别时可能返回 0,0,0,0"],
  params=[{"name": "无", "type": "—", "desc": "无参数", "required": False, "default": None}],
  returns={"type": "number,number,number,number", "desc": "x, y, w, h 逻辑坐标"},
  usage="local x,y,w,h = Device.gameArea()\n-- 或 设备.游戏区域()",
  example="""Device.refresh()
local x,y,w,h = Device.gameArea()
Log.write(string.format("gameRect=%d,%d %dx%d", x,y,w,h))
-- 禁止：用固定物理像素点击；请用比例/设计坐标""")

D("Zy.Device.unlock",
  zh_name="解锁", zh_desc="尝试解锁设备屏幕。",
  purpose="息屏/锁屏时恢复可操作状态。",
  scenario="定时任务唤醒；跑脚本前确保亮屏。",
  principle="deviceUnlock / unlockDevice。",
  related=["Zy.App.launch", "Zy.Screen.sync"],
  errors=["无权限或无 API 时返回 false"],
  params=[{"name": "无", "type": "—", "desc": "无参数", "required": False, "default": None}],
  returns={"type": "boolean", "desc": "是否发起解锁成功"},
  usage="Device.unlock()",
  example="if not Device.unlock() then Log.write(\"unlock failed\") end\nmSleep(800)\nScreen.sync(1)")

# ---------- Screen ----------
D("Zy.Screen.sync",
  zh_name="同步", zh_desc="按方向与 Bundle 同步屏幕坐标系，后续取色/点击才正确。",
  purpose="建立逻辑坐标与当前界面的映射。",
  scenario="每次切应用、旋转、脚本 begin 后。",
  principle="syncScreen(orient, bid)，标记管道 Screen 就绪。",
  related=["Zy.Device.refresh", "Zy.Coordinate.setDesign", "Zy.Touch.tapRatio"],
  errors=["同步失败时坐标可能偏移"],
  params=[
    {"name": "orient", "type": "number", "desc": "方向：0竖屏Home下，1横屏Home右，2横屏Home左", "required": False, "default": 1},
    {"name": "bid", "type": "string", "desc": "目标 Bundle ID，默认上下文", "required": False, "default": "当前 bid"},
  ],
  returns={"type": "boolean", "desc": "是否同步成功"},
  usage="Screen.sync(1, bid)",
  example="""Script.begin({bid=\"com.example.app\", design_w=1136, design_h=640, orient=1})
Screen.sync(1, \"com.example.app\")
local w,h = Screen.size()
Log.write(w .. \"x\" .. h)""")

D("Zy.Screen.info",
  zh_name="信息", zh_desc="返回屏幕信息表（逻辑宽高等）。",
  purpose="调试与适配。",
  scenario="打印当前逻辑分辨率。",
  principle="syncInfo 或由 size 组装 {logic_w,logic_h}。",
  related=["Zy.Screen.size"],
  errors=[],
  params=[{"name": "无", "type": "—", "desc": "无参数", "required": False, "default": None}],
  returns={"type": "table", "desc": "含 logic_w/logic_h 等字段"},
  usage="local si = Screen.info()",
  example="local si = Screen.info()\nlocal w = si.logic_w or si.w\nLog.write(\"screen=\" .. tostring(w))")

D("Zy.Screen.size",
  zh_name="尺寸", zh_desc="返回当前逻辑宽、高。",
  purpose="比例点击与区域计算的基准。",
  scenario="自定义比例换算；日志。",
  principle="screenSize/getScreenSize 或画像 logic_w/h。",
  related=["Zy.Coordinate.ratio", "Zy.Screen.info"],
  errors=[],
  params=[{"name": "无", "type": "—", "desc": "无参数", "required": False, "default": None}],
  returns={"type": "number, number", "desc": "logic_w, logic_h"},
  usage="local w,h = Screen.size()",
  example="local w,h = Screen.size()\n-- 点击屏幕中央偏下（比例，非固定像素）\nTouch.atRatio(0.50, 0.72)")

D("Zy.Screen.snapshot",
  zh_name="截图", zh_desc="截取当前屏幕并返回保存路径。",
  purpose="失败取证、OCR 输入、人工复盘。",
  scenario="Verify 失败；AI.collect；案例归档。",
  principle="snapshot/screenDump 写到 Media/ZiYan/_zy_<tag>.png。",
  related=["Zy.Verify.failReport", "Zy.OCR.region"],
  errors=["无截图 API 时返回 nil"],
  params=[{"name": "tag", "type": "string", "desc": "文件名标签", "required": False, "default": "shot"}],
  returns={"type": "string|nil", "desc": "PNG 路径"},
  usage="local path = Screen.snapshot(\"login\")",
  example="local path = Screen.snapshot(\"fail_login\")\nLog.write(\"shot=\" .. tostring(path))")

D("Zy.Screen.keep",
  zh_name="锁帧", zh_desc="打开/关闭屏幕帧缓存，找色更稳。",
  purpose="连续 findColor 时减少画面抖动。",
  scenario="多点找色循环前 keep(true)，结束后 keep(false)。",
  principle="keepScreen(on)。",
  related=["Zy.Image.findColor", "Zy.OCR.find"],
  errors=[],
  params=[{"name": "on", "type": "boolean", "desc": "true 锁帧，false 释放", "required": True, "default": None}],
  returns={"type": "boolean", "desc": "是否调用成功"},
  usage="Screen.keep(true)",
  example="Screen.keep(true)\nlocal x,y = Image.findColor(0xE8C070, \"\", 90, 0, 0, 1136, 640)\nScreen.keep(false)\nif x~=-1 then Touch.atHit(x,y) end")

# ---------- Coordinate ----------
D("Zy.Coordinate.setDesign",
  zh_name="设设计分辨率", zh_desc="设置设计稿宽高，之后点/区均相对该设计坐标。",
  purpose="一套脚本适配多机：设计坐标→逻辑坐标。",
  scenario="Script.begin 时；切换设计稿。",
  principle="写入会话 design_w/h，供 point/region 换算。",
  related=["Zy.Coordinate.point", "Zy.Script.begin", "Zy.Touch.tapDesign"],
  errors=["非法宽高可能导致换算错误"],
  params=[
    {"name": "w", "type": "number", "desc": "设计宽度，如 1136", "required": True, "default": None},
    {"name": "h", "type": "number", "desc": "设计高度，如 640", "required": True, "default": None},
  ],
  returns={"type": "—", "desc": "无特定返回（写入上下文）"},
  usage="Coordinate.setDesign(1136, 640)\nCoordinate.design(1136, 640)  -- 短别名",
  example="Coordinate.setDesign(1136, 640)\nTouch.atDesign(900, 460)  -- 设计点，不是物理 900,460 死坐标")

D("Zy.Coordinate.design",
  zh_name="设计分辨率", zh_desc="读取当前设计宽高。",
  purpose="确认会话设计分辨率。",
  scenario="调试；动态计算。",
  principle="读上下文 design_w/h。",
  related=["Zy.Coordinate.setDesign"],
  errors=[],
  params=[{"name": "无或可选", "type": "—", "desc": "若作为 setDesign 别名则可传 w,h", "required": False, "default": None}],
  returns={"type": "number, number", "desc": "design_w, design_h（读时）"},
  usage="local dw,dh = Coordinate.design()",
  example="local dw,dh = Coordinate.design()\nLog.write(dw .. \"x\" .. dh)")

D("Zy.Coordinate.point",
  zh_name="点", zh_desc="设计点 (dx,dy) 转换为逻辑点。",
  purpose="设计稿标注坐标落地到真机逻辑像素。",
  scenario="从设计工具导出的按钮中心点。",
  principle="按 design 与当前 Screen.size 比例映射。",
  related=["Zy.Touch.tapDesign", "Zy.Image.colorAtDesign"],
  errors=["未 setDesign 会报错"],
  params=[
    {"name": "dx", "type": "number", "desc": "设计 X", "required": True, "default": None},
    {"name": "dy", "type": "number", "desc": "设计 Y", "required": True, "default": None},
  ],
  returns={"type": "number, number", "desc": "逻辑 lx, ly"},
  usage="local lx,ly = Coordinate.point(568, 320)",
  example="Coordinate.setDesign(1136, 640)\nlocal lx,ly = Coordinate.point(900, 460)\nTouch.atHit(lx, ly)")

D("Zy.Coordinate.ratio",
  zh_name="比例点", zh_desc="将 0~1 比例转换为逻辑点。",
  purpose="分辨率无关的点击/滑动。",
  scenario="按钮在屏幕相对位置固定时。",
  principle="lx=rx*w, ly=ry*h。",
  related=["Zy.Touch.tapRatio", "Zy.Touch.swipeRatio"],
  errors=[],
  params=[
    {"name": "rx", "type": "number", "desc": "横向比例 0~1", "required": True, "default": None},
    {"name": "ry", "type": "number", "desc": "纵向比例 0~1", "required": True, "default": None},
  ],
  returns={"type": "number, number", "desc": "逻辑 lx, ly"},
  usage="local lx,ly = Coordinate.ratio(0.5, 0.72)",
  example="-- 正确：比例点击（推荐）\nTouch.atRatio(0.64, 0.72)\n-- 错误示例（禁止）：Touch.click(500, 300) 固定物理像素")

D("Zy.Coordinate.region",
  zh_name="区域", zh_desc="设计矩形区域转为逻辑矩形。",
  purpose="找色/OCR 限定 ROI。",
  scenario="只在右下角登录区找色。",
  principle="对四角分别 point 映射。",
  related=["Zy.Image.findColor", "Zy.OCR.region"],
  errors=[],
  params=[
    {"name": "x1", "type": "number", "desc": "设计左", "required": True, "default": None},
    {"name": "y1", "type": "number", "desc": "设计上", "required": True, "default": None},
    {"name": "x2", "type": "number", "desc": "设计右", "required": True, "default": None},
    {"name": "y2", "type": "number", "desc": "设计下", "required": True, "default": None},
  ],
  returns={"type": "number×4", "desc": "逻辑 x1,y1,x2,y2"},
  usage="local a,b,c,d = Coordinate.region(600,400,1100,620)",
  example="local a,b,c,d = Coordinate.region(600, 400, 1100, 620)\nlocal x,y = Image.findColor(0xD4A017, \"\", 85, 600, 400, 1100, 620)")

# ---------- Touch (强调禁止固定物理 click) ----------
D("Zy.Touch.tapRatio",
  zh_name="点比例", zh_desc="按屏幕宽高 0~1 比例点击（推荐主入口）。",
  purpose="多机分辨率适配点击，禁止写死物理像素。",
  scenario="登录按钮、确认按钮、主界面入口。",
  principle="Screen.sync → Coordinate.ratio → 引擎 tap/touchDown-Up。",
  related=["Zy.Coordinate.ratio", "Zy.Verify.act", "Zy.Touch.tapDesign"],
  errors=["未同步屏幕可能导致偏移"],
  params=[
    {"name": "rx", "type": "number", "desc": "横向比例 0~1，如 0.64", "required": True, "default": None},
    {"name": "ry", "type": "number", "desc": "纵向比例 0~1，如 0.72", "required": True, "default": None},
    {"name": "hold_ms", "type": "number", "desc": "按住毫秒，可选", "required": False, "default": 70},
  ],
  returns={"type": "boolean, number, number", "desc": "是否成功, 逻辑x, 逻辑y"},
  usage="Touch.atRatio(0.64, 0.72)\n触控.点比例(0.64, 0.72)",
  example="""-- 真实可运行示例（比例，不是物理 500,300）
Screen.sync(1)
Coordinate.setDesign(1136, 640)
local ok = Touch.atRatio(0.64, 0.72)
-- 带验证
Verify.act(\"login_cta\", function()
  Touch.atRatio(0.64, 0.72)
end, 800)""")

D("Zy.Touch.tapDesign",
  zh_name="点设计", zh_desc="按设计稿坐标点击。",
  purpose="设计标注点直接落地。",
  scenario="UI 标注文件给出的按钮中心。",
  principle="Coordinate.point → tap。",
  related=["Zy.Coordinate.setDesign", "Zy.Coordinate.point"],
  errors=["未 setDesign 会失败"],
  params=[
    {"name": "dx", "type": "number", "desc": "设计 X", "required": True, "default": None},
    {"name": "dy", "type": "number", "desc": "设计 Y", "required": True, "default": None},
    {"name": "hold_ms", "type": "number", "desc": "按住毫秒", "required": False, "default": 70},
  ],
  returns={"type": "boolean, number, number", "desc": "ok, lx, ly"},
  usage="Touch.atDesign(900, 460)",
  example="Coordinate.setDesign(1136, 640)\nTouch.atDesign(900, 460)")

D("Zy.Touch.tapHit",
  zh_name="点命中", zh_desc="点击视觉/找色返回的逻辑命中点。",
  purpose="识别结果驱动点击，避免手写坐标。",
  scenario="OCR 找到「登录」后点击。",
  principle="直接对逻辑点 tap（点必须来自 Vision/Image/OCR）。",
  related=["Zy.Vision.analyze", "Zy.Image.findColor", "Zy.OCR.find"],
  errors=["x/y 无效返回 false"],
  params=[
    {"name": "lx", "type": "number", "desc": "逻辑 X（来自识别）", "required": True, "default": None},
    {"name": "ly", "type": "number", "desc": "逻辑 Y", "required": True, "default": None},
    {"name": "hold_ms", "type": "number", "desc": "按住毫秒", "required": False, "default": 70},
  ],
  returns={"type": "boolean, number, number", "desc": "ok, lx, ly"},
  usage="Touch.atHit(x, y)",
  example="""local hit, kind, x, y = Vision.analyze({words={\"登录\",\"进入\"}, design_w=1136, design_h=640})
if hit and x and x~=-1 then
  Touch.atHit(x, y)
end""")

D("Zy.Touch.tap",
  zh_name="禁止裸点", zh_desc="已禁用：禁止固定物理/裸逻辑坐标点击。",
  purpose="防止脚本绕过坐标管道写死坐标。",
  scenario="误调用时立即报错，引导改用 atRatio/atDesign/atHit。",
  principle="直接 error，不执行触控。",
  related=["Zy.Touch.tapRatio", "Zy.Touch.tapDesign", "Zy.Touch.tapHit"],
  errors=["调用即抛错：use tapDesign / tapRatio / tapHit"],
  status="deprecated",
  deprecated_reason="固定坐标自动化不可跨设备复用，且违反子砚管道。",
  replacement="Zy.Touch.tapRatio / tapDesign / tapHit",
  migration="将 Touch.tap(500,300) 改为 Touch.atRatio(500/w, 300/h) 或设计坐标 atDesign。",
  params=[
    {"name": "x", "type": "number", "desc": "禁止使用", "required": True, "default": None},
    {"name": "y", "type": "number", "desc": "禁止使用", "required": True, "default": None},
  ],
  returns={"type": "—", "desc": "不返回，抛错"},
  usage="-- 禁止：Touch.tap(500, 300)",
  example="""-- ❌ 禁止（类似其他平台 Touch.click(500,300)）
-- Touch.tap(500, 300)
-- ✅ 正确
Touch.atRatio(0.44, 0.47)""")

D("Zy.Touch.swipeRatio",
  zh_name="滑比例", zh_desc="按比例从起点滑动到终点。",
  purpose="列表滚动、翻页、手势导航。",
  scenario="上滑关闭弹窗；滑动选服列表。",
  principle="两端 Coordinate.ratio，中间 touchMove 插值。",
  related=["Zy.Touch.gesture", "Zy.Coordinate.ratio"],
  errors=["无 touchMove 时降级为两端轻点"],
  params=[
    {"name": "rx1", "type": "number", "desc": "起点比例X", "required": True, "default": None},
    {"name": "ry1", "type": "number", "desc": "起点比例Y", "required": True, "default": None},
    {"name": "rx2", "type": "number", "desc": "终点比例X", "required": True, "default": None},
    {"name": "ry2", "type": "number", "desc": "终点比例Y", "required": True, "default": None},
    {"name": "steps", "type": "number", "desc": "插值步数", "required": False, "default": 12},
    {"name": "step_ms", "type": "number", "desc": "步间隔毫秒", "required": False, "default": 16},
  ],
  returns={"type": "boolean, ...", "desc": "是否成功及起止逻辑点"},
  usage="Touch.swipe(0.5, 0.75, 0.5, 0.35)",
  example="-- 从下部滑向上部（关闭面板）\nTouch.swipeRatio(0.50, 0.80, 0.50, 0.30, 15, 20)")

D("Zy.Touch.gesture",
  zh_name="手势", zh_desc="按比例点序列执行按下-移动-抬起。",
  purpose="复杂轨迹手势。",
  scenario="曲线滑动；多段拖动。",
  principle="点列 ratio→逻辑，touchDown/Move/Up。",
  related=["Zy.Touch.swipeRatio"],
  errors=["少于 2 点返回 false"],
  params=[
    {"name": "points", "type": "table", "desc": "{{rx,ry},...} 或 {{rx=,ry=},...}", "required": True, "default": None},
    {"name": "step_ms", "type": "number", "desc": "点间间隔", "required": False, "default": 20},
  ],
  returns={"type": "boolean [, string]", "desc": "是否成功"},
  usage="Touch.gesture({{0.2,0.5},{0.5,0.5},{0.8,0.5}})",
  example="Touch.gesture({\n  {rx=0.2, ry=0.5},\n  {rx=0.8, ry=0.5},\n}, 25)")

D("Zy.Touch.longPress",
  zh_name="长按", zh_desc="在设计坐标处按下并保持指定毫秒，用于触发长按菜单。",
  purpose="触发长按菜单。",
  scenario="道具长按；头像长按。",
  principle="tapDesign 延长 hold_ms。",
  related=["Zy.Touch.tapDesign"],
  errors=[],
  params=[
    {"name": "dx", "type": "number", "desc": "设计X", "required": True, "default": None},
    {"name": "dy", "type": "number", "desc": "设计Y", "required": True, "default": None},
    {"name": "hold_ms", "type": "number", "desc": "按住时长", "required": False, "default": 800},
  ],
  returns={"type": "boolean, number, number", "desc": "ok, lx, ly"},
  usage="Touch.longPress(568, 320, 1000)",
  example="Coordinate.setDesign(1136, 640)\nTouch.longPress(568, 320, 1000)")

D("Zy.Touch.swipe",
  zh_name="滑动", zh_desc="swipeRatio 的短别名，参数同为比例。",
  purpose="更短的滑动调用名。",
  scenario="同 swipeRatio。",
  principle="与 swipeRatio 同一函数。",
  related=["Zy.Touch.swipeRatio"],
  errors=[],
  params=[
    {"name": "rx1", "type": "number", "desc": "起点比例X", "required": True, "default": None},
    {"name": "ry1", "type": "number", "desc": "起点比例Y", "required": True, "default": None},
    {"name": "rx2", "type": "number", "desc": "终点比例X", "required": True, "default": None},
    {"name": "ry2", "type": "number", "desc": "终点比例Y", "required": True, "default": None},
  ],
  returns={"type": "boolean, ...", "desc": "同 swipeRatio"},
  usage="Touch.swipe(0.5, 0.8, 0.5, 0.3)",
  example="Touch.swipe(0.5, 0.8, 0.5, 0.3)")

# ---------- Vision / Image / OCR ----------
D("Zy.Vision.analyze",
  zh_name="分析", zh_desc="按词表综合视觉分析（OCR/找色），返回命中点。",
  purpose="一站式找按钮文字或色块。",
  scenario="登录页找「登录」；弹窗找「确定」。",
  principle="转调 OCR.analyze / visionAnalyze，区域经 Coordinate。",
  related=["Zy.OCR.analyze", "Zy.Touch.tapHit", "Zy.Image.findColor"],
  errors=["全未命中返回 false"],
  params=[{"name": "opts", "type": "table", "desc": "{words, design_w, design_h, x1..y2, main_color?}", "required": False, "default": "{}"}],
  returns={"type": "boolean, string, number, number, number, table", "desc": "hit, kind, x, y, color, detail"},
  usage="local hit,kind,x,y = Vision.analyze({words={\"登录\"}, design_w=1136, design_h=640})",
  example="""local hit, kind, x, y = Vision.analyze({
  words = {\"登录\", \"进入\", \"开始\"},
  design_w = 1136, design_h = 640,
})
if hit then Touch.atHit(x, y) else Touch.atRatio(0.64, 0.72) end""")

D("Zy.Vision.findColor", zh_name="找色", zh_desc="视觉门面找色，转调 Image.findColor。",
  purpose="统一从 Vision 调用找色。", scenario="脚本只依赖 Vision 门面时。",
  principle="Zy.Image.findColor(...)。", related=["Zy.Image.findColor"],
  errors=[], params=[{"name": "...", "type": "同 Image.findColor", "desc": "主色/偏移/相似度/设计区", "required": True, "default": None}],
  returns={"type": "number, number", "desc": "x,y 或 -1,-1"},
  usage="Vision.findColor(0xE8C070, \"\", 90, 0, 0, 1136, 640)",
  example="local x,y = Vision.findColor(0xE8C070, \"\", 90, 600, 400, 1100, 620)\nif x~=-1 then Touch.atHit(x,y) end")

D("Zy.Vision.findImage", zh_name="找图", zh_desc="视觉门面找图，转调 Image.find。",
  purpose="模板图匹配。", scenario="固定图标按钮。",
  principle="Zy.Image.find(...)。", related=["Zy.Image.find"],
  errors=[], params=[{"name": "...", "type": "同 Image.find", "desc": "路径/模糊/区域", "required": True, "default": None}],
  returns={"type": "number, number", "desc": "左上角或 -1,-1"},
  usage="Vision.findImage(\"btn.png\", 0.9)",
  example="local x,y = Vision.findImage(\"/private/var/mobile/Media/ZiYan/res/ok.png\", 0.88)\nif x~=-1 then Touch.atHit(x+10, y+10) end")

D("Zy.Vision.colorAt", zh_name="取色", zh_desc="按设计坐标读取屏幕像素颜色，用于判断控件状态。", purpose="判断按钮状态色。",
  scenario="登录钮是否可点。", principle="Image.colorAtDesign。", related=["Zy.Image.colorAtDesign"],
  errors=[], params=[{"name": "dx", "type": "number", "desc": "设计X", "required": True, "default": None},
                     {"name": "dy", "type": "number", "desc": "设计Y", "required": True, "default": None}],
  returns={"type": "number, number, number", "desc": "color, lx, ly"},
  usage="local c = Vision.colorAt(900, 460)",
  example="Coordinate.setDesign(1136,640)\nlocal c = select(1, Vision.colorAt(900,460))\nLog.write(string.format(\"color=%06X\", c))")

D("Zy.Vision.ocr", zh_name="识字", zh_desc="对设计坐标系下的矩形区域做 OCR，返回识别文本。", purpose="读屏文字。",
  scenario="验证码旁提示；版本号。", principle="OCR.region。", related=["Zy.OCR.region"],
  errors=[], params=[{"name": "x1..y2", "type": "number", "desc": "设计区域", "required": True, "default": None}],
  returns={"type": "boolean, string, string", "desc": "ok, text, via"},
  usage="local ok, text = Vision.ocr(0,0,1136,200)",
  example="local ok, text = Vision.ocr(100, 80, 1000, 200)\nif ok then Log.write(text) end")

D("Zy.Vision.findText", zh_name="找字", zh_desc="在屏幕中查找目标文字并返回命中坐标，便于随后点击。", purpose="按字点击。",
  scenario="点「同意」。", principle="OCR.find。", related=["Zy.OCR.find", "Zy.Touch.tapHit"],
  errors=[], params=[{"name": "word", "type": "string", "desc": "目标字", "required": True, "default": None}],
  returns={"type": "number, number, string", "desc": "x,y,via"},
  usage="local x,y = Vision.findText(\"同意\")",
  example="local x,y = Vision.findText(\"同意\", 0, 0, 1136, 640)\nif x~=-1 then Touch.atHit(x,y) end")

D("Zy.Image.findColor",
  zh_name="找色", zh_desc="在设计区域内多点模糊找色。",
  purpose="定位金色按钮、高亮控件。",
  scenario="登录金钮；活动入口色块。",
  principle="Coordinate.region → findMultiColorInRegionFuzzy。",
  related=["Zy.Image.findUntil", "Zy.Touch.tapHit", "Zy.Screen.keep"],
  errors=["未找到返回 -1,-1"],
  params=[
    {"name": "main", "type": "number", "desc": "主色 0xRRGGBB", "required": True, "default": None},
    {"name": "offset", "type": "string", "desc": "偏移色串", "required": False, "default": "\"\""},
    {"name": "sim", "type": "number", "desc": "相似度 0~100", "required": False, "default": 90},
    {"name": "x1", "type": "number", "desc": "设计左", "required": False, "default": 0},
    {"name": "y1", "type": "number", "desc": "设计上", "required": False, "default": 0},
    {"name": "x2", "type": "number", "desc": "设计右", "required": False, "default": "design_w"},
    {"name": "y2", "type": "number", "desc": "设计下", "required": False, "default": "design_h"},
  ],
  returns={"type": "number, number", "desc": "命中 x,y；失败 -1,-1"},
  usage="Image.findColor(0xE8C070, \"\", 88, 600, 400, 1100, 620)",
  example="""Coordinate.setDesign(1136, 640)
Screen.keep(true)
local x, y = Image.findColor(0xE8C070, \"\", 88, 600, 400, 1100, 620)
Screen.keep(false)
if x ~= -1 then Touch.atHit(x, y) end""")

D("Zy.Image.find",
  zh_name="找图", zh_desc="设计区域内模板找图。",
  purpose="匹配固定图标。",
  scenario="设置齿轮图标。",
  principle="Coordinate.region → findImageInRegionFuzzy。",
  related=["Zy.Touch.tapHit"],
  errors=["失败 -1,-1"],
  params=[
    {"name": "path", "type": "string", "desc": "模板图路径", "required": True, "default": None},
    {"name": "fuzzy", "type": "number", "desc": "相似度", "required": False, "default": 0.9},
    {"name": "x1..y2", "type": "number", "desc": "可选设计 ROI", "required": False, "default": "全屏"},
  ],
  returns={"type": "number, number", "desc": "左上角坐标"},
  usage="Image.find(path, 0.9)",
  example="local x,y = Image.find(File.scriptsDir() .. \"/../res/gear.png\", 0.9)\nif x~=-1 then Touch.atHit(x+15, y+15) end")

D("Zy.Image.colorAtDesign",
  zh_name="取色", zh_desc="设计坐标取色。",
  purpose="状态色判断。",
  scenario="检测按钮是否高亮。",
  principle="point → getColor。",
  related=["Zy.Image.colorAtLogic", "Zy.Vision.colorAt"],
  errors=[],
  params=[{"name": "dx", "type": "number", "desc": "设计X", "required": True, "default": None},
          {"name": "dy", "type": "number", "desc": "设计Y", "required": True, "default": None}],
  returns={"type": "number, number, number", "desc": "color, lx, ly"},
  usage="Image.colorAt(900, 460)",
  example="local c = select(1, Image.colorAtDesign(900, 460))\nif c > 0xC00000 then Log.write(\"reddish\") end")

D("Zy.Image.colorAtLogic",
  zh_name="取色逻辑点", zh_desc="已同步屏幕上的逻辑点取色。",
  purpose="对识别点复核颜色。",
  scenario="命中点校验。",
  principle="getColor(lx,ly)。",
  related=["Zy.Image.colorAtDesign"],
  errors=[],
  params=[{"name": "lx", "type": "number", "desc": "逻辑X", "required": True, "default": None},
          {"name": "ly", "type": "number", "desc": "逻辑Y", "required": True, "default": None}],
  returns={"type": "number", "desc": "颜色值"},
  usage="Image.colorAtPx(lx, ly)",
  example="local c = Image.colorAtLogic(100, 200)")

D("Zy.Image.findUntil",
  zh_name="等到找色", zh_desc="超时内轮询找色直到命中。",
  purpose="等待动画/加载后控件出现。",
  scenario="等待登录钮渲染完成。",
  principle="循环 findColor + mSleep。",
  related=["Zy.Image.findColor", "Zy.Script.untilPhase"],
  errors=["超时返回 false,-1,-1"],
  params=[
    {"name": "main", "type": "number", "desc": "主色", "required": True, "default": None},
    {"name": "offset", "type": "string", "desc": "偏移串", "required": False, "default": "\"\""},
    {"name": "sim", "type": "number", "desc": "相似度", "required": False, "default": 90},
    {"name": "x1..y2", "type": "number", "desc": "设计区", "required": False, "default": None},
    {"name": "timeout_ms", "type": "number", "desc": "超时", "required": False, "default": 5000},
    {"name": "interval_ms", "type": "number", "desc": "间隔", "required": False, "default": 400},
  ],
  returns={"type": "boolean, number, number", "desc": "是否命中, x, y"},
  usage="Image.findUntil(0xE8C070, \"\", 88, 600,400,1100,620, 8000, 400)",
  example="local ok,x,y = Image.findUntil(0xE8C070, \"\", 88, 600,400,1100,620, 8000)\nif ok then Touch.atHit(x,y) end")

D("Zy.OCR.region",
  zh_name="区域识字", zh_desc="识别设计区域内全部文字。",
  purpose="读提示语、账号区。",
  scenario="判断是否仍在登录页。",
  principle="visionOcr。",
  related=["Zy.OCR.find", "Zy.Vision.ocr"],
  errors=["无 OCR 返回 false"],
  params=[{"name": "x1", "type": "number", "desc": "设计左", "required": True, "default": None},
          {"name": "y1", "type": "number", "desc": "设计上", "required": True, "default": None},
          {"name": "x2", "type": "number", "desc": "设计右", "required": True, "default": None},
          {"name": "y2", "type": "number", "desc": "设计下", "required": True, "default": None}],
  returns={"type": "boolean, string, string", "desc": "ok, text, via"},
  usage="OCR.region(0,0,1136,200)",
  example="local ok, text = OCR.region(50, 50, 1080, 180)\nif ok and text:find(\"登录\") then Log.write(\"on login\") end")

D("Zy.OCR.find",
  zh_name="找字", zh_desc="在设计区查找目标字并返回坐标。",
  purpose="按文字点击。",
  scenario="点「进入游戏」。",
  principle="visionFindText。",
  related=["Zy.Touch.tapHit", "Zy.OCR.findUntil"],
  errors=["未找到 -1,-1"],
  params=[{"name": "word", "type": "string", "desc": "目标文字", "required": True, "default": None},
          {"name": "x1..y2", "type": "number", "desc": "可选设计区", "required": False, "default": None}],
  returns={"type": "number, number, string", "desc": "x,y,via"},
  usage="OCR.find(\"进入\")",
  example="local x,y = OCR.find(\"进入\", 0, 300, 1136, 640)\nif x~=-1 then Touch.atHit(x,y) end")

D("Zy.OCR.analyze",
  zh_name="分析", zh_desc="多词表 OCR/色综合分析。",
  purpose="同 Vision.analyze。",
  scenario="状态分类辅助。",
  principle="visionAnalyze。",
  related=["Zy.Vision.analyze"],
  errors=[],
  params=[{"name": "opts", "type": "table", "desc": "words/design 等", "required": False, "default": "{}"}],
  returns={"type": "boolean, ...", "desc": "同 Vision.analyze"},
  usage="OCR.analyze({words={\"确定\"}})",
  example="local hit,_,_,x,y = OCR.analyze({words={\"确定\",\"取消\"}, design_w=1136, design_h=640})")

D("Zy.OCR.findUntil",
  zh_name="等到找字", zh_desc="超时内轮询找字。",
  purpose="等待文案出现。",
  scenario="加载完成后出现「开始」。",
  principle="循环 OCR.find。",
  related=["Zy.OCR.find"],
  errors=["超时 false"],
  params=[{"name": "word", "type": "string", "desc": "目标字", "required": True, "default": None},
          {"name": "timeout_ms", "type": "number", "desc": "超时", "required": False, "default": 5000}],
  returns={"type": "boolean, number, number, string", "desc": "ok,x,y,via"},
  usage="OCR.findUntil(\"开始\", 0,0,1136,640, 10000)",
  example="local ok,x,y = OCR.findUntil(\"开始\", 0, 0, 1136, 640, 10000, 500)\nif ok then Touch.atHit(x,y) end")

# ---------- File / Network / Verify / SM / Game / Script / Config / Input / Log ----------
D("Zy.File.read", zh_name="读", zh_desc="读取文本文件全部内容。",
  purpose="读配置/记录。", scenario="读上次运行相位。",
  principle="io.open 读 *a。", related=["Zy.File.write", "Zy.Config.load"],
  errors=["不存在返回 nil"],
  params=[{"name": "path", "type": "string", "desc": "绝对路径", "required": True, "default": None}],
  returns={"type": "string|nil", "desc": "文件内容"},
  usage="File.read(path)",
  example="local t = File.read(File.varDir() .. \"/.ziyan_ai_loop.txt\")\nLog.write(tostring(t))")

D("Zy.File.write", zh_name="写", zh_desc="写入文本（覆盖）。",
  purpose="落盘状态/报告。", scenario="写冒烟结果。",
  principle="io.open w。", related=["Zy.File.read"],
  errors=[],
  params=[{"name": "path", "type": "string", "desc": "路径", "required": True, "default": None},
          {"name": "body", "type": "string", "desc": "内容", "required": True, "default": None}],
  returns={"type": "boolean", "desc": "是否写入"},
  usage="File.write(path, body)",
  example="File.write(File.varDir() .. \"/last.txt\", \"phase=login\\n\")")

D("Zy.File.exists", zh_name="存在", zh_desc="判断路径是否存在。",
  purpose="分支逻辑。", scenario="有配置则加载。",
  principle="io.open 探测。", related=["Zy.File.read"],
  errors=[],
  params=[{"name": "path", "type": "string", "desc": "路径", "required": True, "default": None}],
  returns={"type": "boolean", "desc": "是否存在"},
  usage="File.exists(path)",
  example="if File.exists(Config.path(\"main\")) then Config.load(\"main\") end")

D("Zy.File.remove", zh_name="删", zh_desc="删除指定路径的文件；不存在时视为成功或忽略错误。",
  purpose="清理临时文件。", scenario="删旧截图。",
  principle="os.remove。", related=["Zy.File.exists"],
  errors=[],
  params=[{"name": "path", "type": "string", "desc": "路径", "required": True, "default": None}],
  returns={"type": "boolean", "desc": "是否删除"},
  usage="File.remove(path)",
  example="File.remove(File.varDir() .. \"/tmp_flag.txt\")")

D("Zy.File.scriptsDir", zh_name="脚本目录", zh_desc="返回用户脚本根目录。",
  purpose="拼脚本路径。", scenario="Script.run 相对路径基准。",
  principle="ZIYAN_SCRIPTS 或 Media/ZiYan/scripts。", related=["Zy.Script.run"],
  errors=[], params=[{"name": "无", "type": "—", "desc": "无", "required": False, "default": None}],
  returns={"type": "string", "desc": "目录路径"},
  usage="File.scriptsDir()",
  example="Log.write(File.scriptsDir())")

D("Zy.File.varDir", zh_name="变量目录", zh_desc="返回运行变量目录。",
  purpose="写运行时标志。", scenario="冒烟结果文件。",
  principle="ZIYAN_VAR 或 /usr/lib/ziyan/var。", related=["Zy.File.write"],
  errors=[], params=[{"name": "无", "type": "—", "desc": "无", "required": False, "default": None}],
  returns={"type": "string", "desc": "目录路径"},
  usage="File.varDir()",
  example="File.write(File.varDir() .. \"/ok.txt\", \"1\")")

D("Zy.Network.httpGet", zh_name="获取", zh_desc="HTTP GET 拉取内容。",
  purpose="拉远程配置/版本。", scenario="更新任务表。",
  principle="pyCall 或 curl。", related=["Zy.Network.httpPost", "Zy.Config.save"],
  errors=["失败返回 false, reason"],
  params=[{"name": "url", "type": "string", "desc": "URL", "required": True, "default": None},
          {"name": "timeout", "type": "number", "desc": "秒", "required": False, "default": 8}],
  returns={"type": "boolean, string", "desc": "ok, body/err"},
  usage="Network.httpGet(url)",
  example="local ok, body = Network.httpGet(\"https://example.com/cfg.json\", 6)\nif ok then Log.write(body:sub(1,80)) end")

D("Zy.Network.httpPost", zh_name="提交", zh_desc="HTTP POST 提交 body。",
  purpose="上报结果。", scenario="案例回传。",
  principle="pyCall 或 curl --data-binary。", related=["Zy.Network.httpGet"],
  errors=["失败 false"],
  params=[{"name": "url", "type": "string", "desc": "URL", "required": True, "default": None},
          {"name": "body", "type": "string", "desc": "请求体", "required": True, "default": None},
          {"name": "timeout", "type": "number", "desc": "秒", "required": False, "default": 8},
          {"name": "headers", "type": "table", "desc": "可选头", "required": False, "default": None}],
  returns={"type": "boolean, string", "desc": "ok, resp"},
  usage="Network.httpPost(url, body)",
  example="Network.httpPost(\"https://example.com/log\", \"ok=1\", 5, {\"Content-Type\"=\"text/plain\"})")

D("Zy.Network.pyCall", zh_name="调Python", zh_desc="调用 Python 侧函数。",
  purpose="重计算/CV 扩展。", scenario="自定义识图。",
  principle="引擎 pyCall。", related=["Zy.Network.httpGet"],
  errors=["无 pyCall 返回 false"],
  params=[{"name": "mod", "type": "string", "desc": "模块名", "required": True, "default": None},
          {"name": "func", "type": "string", "desc": "函数名", "required": True, "default": None},
          {"name": "args", "type": "table", "desc": "参数", "required": False, "default": None}],
  returns={"type": "any", "desc": "Python 返回"},
  usage="Network.pyCall(\"ziyan_net\", \"http_get\", {url=u})",
  example="local ok, res = Network.pyCall(\"ziyan_net\", \"http_get\", {url=\"https://example.com\", timeout=5})")

D("Zy.Verify.act",
  zh_name="执行并验证", zh_desc="执行动作后比对画面指纹/相位，禁止默认成功。",
  purpose="确认点击真正推进界面。",
  scenario="点登录后必须离开 login 相位。",
  principle="fingerprint → act → wait → fingerprint → changed；login 下色差不算成功。",
  related=["Zy.Touch.tapRatio", "Zy.Script.recover", "Zy.Verify.failReport"],
  errors=["still_login / no_change → ok=false"],
  params=[{"name": "label", "type": "string", "desc": "动作标签", "required": True, "default": None},
          {"name": "act_fn", "type": "function", "desc": "无参触控闭包", "required": True, "default": None},
          {"name": "wait_ms", "type": "number", "desc": "等待毫秒", "required": False, "default": 1200}],
  returns={"type": "boolean, table, string", "desc": "ok, after指纹, reason"},
  usage="Verify.act(\"cta\", function() Touch.atRatio(0.64,0.72) end, 800)",
  example="""local ok, after, reason = Verify.act(\"login_cta\", function()
  Touch.atRatio(0.64, 0.72)
end, 800)
if not ok then
  Verify.fail({reason=reason, phase=after and after.phase})
  Script.recover({reason=reason, frame=after, policy=\"resync\"})
end""")

D("Zy.Verify.fingerprint", zh_name="指纹", zh_desc="采集当前画面相位与采样点色。",
  purpose="动作前后对比。", scenario="自定义验证。",
  principle="sync + phase + 多点 getColor。", related=["Zy.Verify.act"],
  errors=[], params=[{"name": "bid", "type": "string", "desc": "可选 Bundle", "required": False, "default": None}],
  returns={"type": "table", "desc": "phase/samples/front/..."},
  usage="local fp = Verify.fingerprint()",
  example="local before = Verify.fingerprint()\nTouch.atRatio(0.5,0.5)\nmSleep(500)\nlocal after = Verify.fingerprint()")

D("Zy.Verify.failReport",
  zh_name="失败报告", zh_desc="写入失败原因、建议与可选截图。",
  purpose="问题归因。", scenario="验证失败后。",
  principle="写 var/.ziyan_fail_report.txt。", related=["Zy.Diagnose.onStuck", "Zy.Script.recover"],
  errors=[],
  params=[{"name": "opts", "type": "table", "desc": "{reason,phase,module,fix,tag}", "required": False, "default": "{}"}],
  returns={"type": "string [, string]", "desc": "报告正文 [, shot]"},
  usage="Verify.fail({reason=\"still_login\"})",
  example="Verify.failReport({reason=\"still_login\", phase=\"login\", module=\"Touch\", fix=\"改用 Vision 命中\"})")

D("Zy.StateMachine.current", zh_name="当前", zh_desc="当前交互状态名。",
  purpose="分支决策。", scenario="主循环判断。",
  principle="委托 Game.phase。", related=["Zy.Game.phase", "Zy.StateMachine.suggest"],
  errors=[], params=[{"name": "bid", "type": "string", "desc": "可选", "required": False, "default": None}],
  returns={"type": "string", "desc": "boot/login/running/..."},
  usage="local st = State.current()",
  example="local st = StateMachine.current()\nif st==\"login\" then Touch.atRatio(0.64,0.72) end")

D("Zy.StateMachine.suggest", zh_name="建议", zh_desc="根据状态给出建议动作标签。",
  purpose="策略提示。", scenario="日志/AI.plan。",
  principle="Game.suggest 映射表。", related=["Zy.Game.suggest"],
  errors=[], params=[{"name": "st", "type": "string", "desc": "状态", "required": True, "default": None}],
  returns={"type": "string", "desc": "建议标签"},
  usage="State.suggest(\"login\")",
  example="Log.write(StateMachine.suggest(StateMachine.current()))")

D("Zy.StateMachine.step", zh_name="步进", zh_desc="按 handler 执行一步并验证。",
  purpose="状态机驱动。", scenario="登录→选角。",
  principle="current → handler → Verify。", related=["Zy.Script.tick"],
  errors=["no_handler / repeat_blocked"],
  params=[{"name": "handlers", "type": "table", "desc": "相位→函数", "required": True, "default": None},
          {"name": "wait_ms", "type": "number", "desc": "等待", "required": False, "default": 1200}],
  returns={"type": "boolean, string, string, string", "desc": "ok, from, to, reason"},
  usage="State.step({login=fn, default=fn})",
  example="StateMachine.step({\n  login=function() Touch.atRatio(0.64,0.72) end,\n  default=function() Touch.atRatio(0.5,0.7) end,\n}, 800)")

D("Zy.StateMachine.canTransit", zh_name="可转移", zh_desc="判断状态转移是否允许。",
  purpose="防乱跳。", scenario="自定义图。",
  principle="转移表校验。", related=["Zy.StateMachine.step"],
  errors=[],
  params=[{"name": "from", "type": "string", "desc": "源", "required": True, "default": None},
          {"name": "to", "type": "string", "desc": "目标", "required": True, "default": None}],
  returns={"type": "boolean", "desc": "是否允许"},
  usage="State.canTransit(\"login\",\"role\")",
  example="if StateMachine.canTransit(\"login\", \"role\") then Log.write(\"ok\") end")

D("Zy.Game.classify", zh_name="分类", zh_desc="通用界面分类（不绑游戏名）。",
  purpose="识别 boot/login/running 等。", scenario="每次 tick 前。",
  principle="窗口→Vision→亮色启发式。", related=["Zy.Game.phase", "Zy.Game.analyze"],
  errors=[],
  params=[{"name": "bid", "type": "string", "desc": "Bundle", "required": False, "default": None}],
  returns={"type": "string, table", "desc": "状态, 细节"},
  usage="local st,d = Game.classify()",
  example="local st, d = Game.classify()\nLog.write(st .. \" via=\" .. tostring(d.via))")

D("Zy.Game.phase", zh_name="相位", zh_desc="当前相位名。",
  purpose="简读状态。", scenario="循环条件。",
  principle="classify 的状态名。", related=["Zy.Game.classify"],
  errors=[], params=[{"name": "bid", "type": "string", "desc": "可选", "required": False, "default": None}],
  returns={"type": "string", "desc": "相位"},
  usage="Game.phase()",
  example="while Game.phase()~=\"running\" do Script.tick({handlers=H}) end")

D("Zy.Game.analyze", zh_name="分析帧", zh_desc="分析当前帧返回结构（可 light 跳过截图）。",
  purpose="一次拿到 phase/detail/shot。", scenario="AI.collect；Script.tick。",
  principle="classify + 可选 snapshot。", related=["Zy.Script.tick"],
  errors=[],
  params=[{"name": "bid", "type": "string", "desc": "可选", "required": False, "default": None},
          {"name": "opts", "type": "table", "desc": "{light=true} 跳过截图", "required": False, "default": None}],
  returns={"type": "table", "desc": "{phase,detail,shot,front,...}"},
  usage="Game.analyze(bid, {light=true})",
  example="local fr = Game.analyze(nil, {light=true})\nLog.write(fr.phase)")

D("Zy.Game.suggest", zh_name="建议", zh_desc="相位→建议动作标签。",
  purpose="策略名。", scenario="日志。",
  principle="映射表。", related=["Zy.StateMachine.suggest"],
  errors=[], params=[{"name": "state", "type": "string", "desc": "相位", "required": True, "default": None}],
  returns={"type": "string", "desc": "建议"},
  usage="Game.suggest(\"login\")",
  example="Log.write(Game.suggest(Game.phase()))")

D("Zy.Game.open", zh_name="打开", zh_desc="启动目标应用。",
  purpose="进应用。", scenario="脚本开头。",
  principle="App.launch。", related=["Zy.App.launch", "Zy.Game.close"],
  errors=[], params=[{"name": "bid", "type": "string", "desc": "Bundle", "required": True, "default": None}],
  returns={"type": "boolean, string", "desc": "ok, front"},
  usage="Game.open(bid)",
  example="Game.open(\"com.example.app\")\nScreen.sync(1, \"com.example.app\")")

D("Zy.Game.close", zh_name="关闭", zh_desc="关闭目标应用进程，常用于异常恢复后的重启前置。",
  purpose="复位。", scenario="恢复策略 relaunch。",
  principle="App.close。", related=["Zy.App.close"],
  errors=[], params=[{"name": "bid", "type": "string", "desc": "Bundle", "required": False, "default": None}],
  returns={"type": "boolean", "desc": "ok"},
  usage="Game.close()",
  example="Game.close()\nmSleep(500)\nGame.open(Script.get(\"bid\"))")

D("Zy.Game.enterRole", zh_name="进角", zh_desc="尝试推进到角色/主界面（需业务条件）。",
  purpose="登录后进游戏。", scenario="有凭证时。",
  principle="分类+点击策略（不保证无账号也能过）。", related=["Zy.Game.stepTo"],
  errors=["凭证缺失时无法进入"],
  params=[{"name": "opts", "type": "table", "desc": "可选", "required": False, "default": None}],
  returns={"type": "boolean, string", "desc": "是否推进, 原因"},
  usage="Game.enterRole()",
  example="local ok, why = Game.enterRole()\nLog.write(tostring(ok) .. \" \" .. tostring(why))")

D("Zy.Game.stepTo", zh_name="步进到", zh_desc="向目标相位推进一步。",
  purpose="靠近目标状态。", scenario="走到 menu。",
  principle="classify + 建议动作。", related=["Zy.Script.tick"],
  errors=[],
  params=[{"name": "target", "type": "string", "desc": "目标相位", "required": True, "default": None}],
  returns={"type": "boolean, string", "desc": "ok, phase"},
  usage="Game.stepTo(\"menu\")",
  example="Game.stepTo(\"running\")")

D("Zy.Game.stateSuggest", zh_name="状态建议", zh_desc="兼容旧名，等同 suggest。",
  purpose="兼容。", scenario="旧脚本。",
  principle="同 suggest。", related=["Zy.Game.suggest"],
  errors=[], params=[{"name": "state", "type": "string", "desc": "状态", "required": True, "default": None}],
  returns={"type": "string", "desc": "建议"},
  usage="Game.stateSuggest(\"login\")",
  example="Log.write(Game.stateSuggest(\"login\"))")

D("Zy.Script.begin",
  zh_name="开始", zh_desc="初始化脚本会话：bid、设计分辨率、方向、同步。",
  purpose="所有自动化入口。",
  scenario="main() 第一句。",
  principle="Device.refresh + Screen.sync + Coordinate.setDesign。",
  related=["Zy.Device.refresh", "Zy.Screen.sync", "Zy.Coordinate.setDesign", "Zy.App.launch"],
  errors=["缺 design_w/h 报错"],
  params=[{"name": "opts", "type": "table", "desc": "{bid, design_w, design_h, orient}", "required": True, "default": None}],
  returns={"type": "table", "desc": "Zy 表"},
  usage="Script.begin({bid=BID, design_w=1136, design_h=640, orient=1})",
  example="""function main()
  Script.begin({
    bid = \"com.example.app\",
    design_w = 1136, design_h = 640, orient = 1,
  })
  App.launch(Script.get(\"bid\"), 1500)
  Screen.sync(1)
end""")

D("Zy.Script.act", zh_name="动作", zh_desc="带 Verify 的动作封装。",
  purpose="可验证点击。", scenario="关键 CTA。",
  principle="Verify.act + Case。", related=["Zy.Verify.act"],
  errors=[],
  params=[{"name": "label", "type": "string", "desc": "标签", "required": True, "default": None},
          {"name": "fn", "type": "function", "desc": "function(ctx)", "required": True, "default": None},
          {"name": "wait_ms", "type": "number", "desc": "等待", "required": False, "default": 1200}],
  returns={"type": "boolean, table, string", "desc": "ok, after, reason"},
  usage="Script.act(\"cta\", function(ctx) ctx.tapRatio(0.5,0.7) end)",
  example="Script.act(\"cta\", function(ctx) ctx.tapRatio(0.64, 0.72) end, 800)")

D("Zy.Script.set", zh_name="设变量", zh_desc="向当前脚本会话写入命名变量，供后续 get/tick 使用。",
  purpose="任务间传状态。", scenario="记 bid/重试次数。",
  principle="_vars 表。", related=["Zy.Script.get"],
  errors=[],
  params=[{"name": "key", "type": "string", "desc": "键", "required": True, "default": None},
          {"name": "value", "type": "any", "desc": "值", "required": True, "default": None}],
  returns={"type": "any", "desc": "value"},
  usage="Script.set(\"retry\", 0)",
  example="Script.set(\"bid\", \"com.example.app\")\nScript.set(\"retry\", Script.get(\"retry\",0)+1)")

D("Zy.Script.get", zh_name="取变量", zh_desc="读取当前脚本会话中的命名变量；不存在时返回 default。",
  purpose="读状态。", scenario="条件判断。",
  principle="读 _vars。", related=["Zy.Script.set"],
  errors=[],
  params=[{"name": "key", "type": "string", "desc": "键", "required": True, "default": None},
          {"name": "default", "type": "any", "desc": "缺省", "required": False, "default": None}],
  returns={"type": "any", "desc": "值"},
  usage="Script.get(\"bid\")",
  example="local bid = Script.get(\"bid\")\nApp.launch(bid)")

D("Zy.Script.tick",
  zh_name="滴答", zh_desc="主循环单步：分析→handler→验证→失败恢复。",
  purpose="状态机脚本核心。",
  scenario="while 中推进界面。",
  principle="Game.analyze → handlers[phase] → Verify → recover。",
  related=["Zy.Game.analyze", "Zy.Script.recover", "Zy.Script.loop"],
  errors=["no_handler"],
  params=[{"name": "opts", "type": "table", "desc": "{handlers, wait_ms}", "required": False, "default": None}],
  returns={"type": "boolean, table, string", "desc": "ok, frame, reason"},
  usage="Script.tick({handlers={login=fn, default=fn}})",
  example="""Script.loop(5, function(i)
  Script.tick({
    handlers = {
      login = function(ctx) ctx.tapRatio(0.64, 0.72) end,
      running = function(ctx) Script.set(\"done\", true) end,
      default = function(ctx) ctx.tapRatio(0.50, 0.70) end,
    },
    wait_ms = 600,
  })
  if Script.get(\"done\") then return false end
end)""")

D("Zy.Script.recover", zh_name="恢复", zh_desc="异常恢复：诊断 + resync/relaunch。",
  purpose="失败自愈。", scenario="still_login。",
  principle="Diagnose/FailReport → sync 或重开 App。",
  related=["Zy.Verify.failReport", "Zy.App.launch"],
  errors=[],
  params=[{"name": "info", "type": "table", "desc": "{reason,frame,policy}", "required": False, "default": None}],
  returns={"type": "boolean", "desc": "已执行"},
  usage="Script.recover({policy=\"resync\", reason=r})",
  example="Script.recover({reason=\"still_login\", policy=\"resync\"})")

D("Zy.Script.loop", zh_name="循环", zh_desc="有限次循环，body 返回 false 结束。",
  purpose="可控主循环。", scenario="最多试 5 次。",
  principle="for + 提前 break。", related=["Zy.Script.tick"],
  errors=[],
  params=[{"name": "max_times", "type": "number", "desc": "最大次数", "required": True, "default": 1},
          {"name": "body", "type": "function", "desc": "function(i,ctx)", "required": True, "default": None}],
  returns={"type": "number", "desc": "实际次数"},
  usage="Script.loop(5, function(i) ... end)",
  example="Script.loop(3, function(i)\n  if Game.phase()==\"running\" then return false end\n  Script.tick({handlers=H})\nend)")

D("Zy.Script.untilPhase", zh_name="等到相位", zh_desc="轮询直到目标相位或超时。",
  purpose="等待加载。", scenario="等到 running。",
  principle="phase 轮询。", related=["Zy.Game.phase"],
  errors=[],
  params=[{"name": "target", "type": "string", "desc": "目标", "required": True, "default": "running"},
          {"name": "timeout_ms", "type": "number", "desc": "超时", "required": False, "default": 15000}],
  returns={"type": "boolean, string", "desc": "是否到达, 最终相位"},
  usage="Script.untilPhase(\"running\", 10000)",
  example="local ok, st = Script.untilPhase(\"running\", 12000, 600)\nLog.write(tostring(ok)..\" \"..st)")

D("Zy.Script.when", zh_name="当", zh_desc="条件成立时执行。",
  purpose="分支。", scenario="仅 login 时点。",
  principle="pred → fn/act。", related=["Zy.Script.act"],
  errors=[],
  params=[{"name": "pred", "type": "function|boolean", "desc": "条件", "required": True, "default": None},
          {"name": "fn", "type": "function", "desc": "动作", "required": True, "default": None}],
  returns={"type": "boolean", "desc": "是否执行"},
  usage="Script.when(function() return Game.phase()==\"login\" end, fn)",
  example="Script.when(function() return Game.phase()==\"login\" end,\n  function(ctx) ctx.tapRatio(0.64,0.72) end, \"login\", 800)")

D("Zy.Script.defineTask", zh_name="定义任务", zh_desc="注册命名任务函数，供 runTask / runTasks 按名调度执行。",
  purpose="任务流。", scenario="open/login/enter。",
  principle="_tasks。", related=["Zy.Script.runTasks"],
  errors=[],
  params=[{"name": "name", "type": "string", "desc": "名", "required": True, "default": None},
          {"name": "fn", "type": "function", "desc": "函数", "required": True, "default": None}],
  returns={"type": "nil", "desc": ""},
  usage="Script.defineTask(\"open\", function() ... end)",
  example="Script.defineTask(\"open\", function()\n  return App.launch(Script.get(\"bid\"))\nend)")

D("Zy.Script.runTask", zh_name="跑任务", zh_desc="执行单个命名任务。",
  purpose="单步任务。", scenario="调试。",
  principle="查表调用。", related=["Zy.Script.defineTask"],
  errors=["任务不存在"],
  params=[{"name": "name", "type": "string", "desc": "任务名", "required": True, "default": None}],
  returns={"type": "any", "desc": "任务返回"},
  usage="Script.runTask(\"open\")",
  example="Script.runTask(\"open\")")

D("Zy.Script.runTasks", zh_name="跑任务列表", zh_desc="按序执行，失败即停。",
  purpose="编排。", scenario="完整流程。",
  principle="顺序 runTask。", related=["Zy.Script.runTask"],
  errors=[],
  params=[{"name": "names", "type": "table", "desc": "任务名数组", "required": True, "default": None}],
  returns={"type": "table", "desc": "结果数组"},
  usage="Script.runTasks({\"open\",\"login\"})",
  example="Script.runTasks({\"open\", \"login\", \"enter\"})")

D("Zy.Script.run", zh_name="运行脚本", zh_desc="加载 scripts 下文件。",
  purpose="组合脚本。", scenario="跑模板。",
  principle="dofile。", related=["Zy.Script.load"],
  errors=["文件不存在"],
  params=[{"name": "rel", "type": "string", "desc": "相对或绝对路径", "required": True, "default": None}],
  returns={"type": "any", "desc": "dofile 返回"},
  usage="Script.run(\"templates/01_basic_automation.lua\")",
  example="Script.run(\"templates/01_basic_automation.lua\")\nif type(main)==\"function\" then main() end")

D("Zy.Script.exit", zh_name="退出", zh_desc="结束会话并记原因。",
  purpose="正常收尾。", scenario="完成目标后。",
  principle="设 exited 标志。", related=["Zy.Script.restart"],
  errors=[],
  params=[{"name": "reason", "type": "string", "desc": "原因", "required": False, "default": "script_exit"}],
  returns={"type": "boolean", "desc": "true"},
  usage="Script.exit(\"done\")",
  example="if Script.get(\"done\") then Script.exit(\"running_reached\") end")

D("Zy.Script.restart", zh_name="重启脚本", zh_desc="请求重新运行入口。",
  purpose="致命错误自救。", scenario="引擎异常后。",
  principle="写 .ziyan_restart_req。", related=["Zy.Script.exit"],
  errors=[],
  params=[{"name": "reason", "type": "string", "desc": "原因", "required": False, "default": None}],
  returns={"type": "boolean", "desc": "true"},
  usage="Script.restart(\"fatal\")",
  example="Script.restart(\"unrecoverable\")")

D("Zy.Script.has", zh_name="有变量", zh_desc="变量是否存在。",
  purpose="分支。", scenario="可选配置。",
  principle="查 _vars。", related=["Zy.Script.get"],
  errors=[],
  params=[{"name": "key", "type": "string", "desc": "键", "required": True, "default": None}],
  returns={"type": "boolean", "desc": "是否存在"},
  usage="Script.has(\"bid\")",
  example="if not Script.has(\"bid\") then error(\"bid required\") end")

D("Zy.Script.clearVars", zh_name="清空变量", zh_desc="清空会话变量。",
  purpose="重置。", scenario="多轮测试。",
  principle="清空 _vars。", related=["Zy.Script.set"],
  errors=[], params=[{"name": "无", "type": "—", "desc": "无", "required": False, "default": None}],
  returns={"type": "—", "desc": ""},
  usage="Script.clearVars()",
  example="Script.clearVars()\nScript.begin({bid=BID, design_w=1136, design_h=640})")

D("Zy.Script.vars", zh_name="变量表", zh_desc="返回变量表。",
  purpose="调试。", scenario="打印状态。",
  principle="返回 _vars。", related=["Zy.Script.get"],
  errors=[], params=[{"name": "无", "type": "—", "desc": "无", "required": False, "default": None}],
  returns={"type": "table", "desc": "变量表"},
  usage="Script.vars()",
  example="for k,v in pairs(Script.vars()) do Log.write(k .. \"=\" .. tostring(v)) end")

D("Zy.Script.lastError", zh_name="最后错误", zh_desc="最近脚本错误。",
  purpose="排障。", scenario="recover 后查询。",
  principle="_last_error。", related=["Zy.Script.recover"],
  errors=[], params=[{"name": "无", "type": "—", "desc": "无", "required": False, "default": None}],
  returns={"type": "string|nil", "desc": "错误"},
  usage="Script.lastError()",
  example="Log.write(tostring(Script.lastError()))")

D("Zy.Script.load", zh_name="加载", zh_desc="dofile 加载路径。",
  purpose="动态加载。", scenario="加载库。",
  principle="dofile。", related=["Zy.Script.run"],
  errors=[],
  params=[{"name": "path", "type": "string", "desc": "绝对路径", "required": True, "default": None}],
  returns={"type": "any", "desc": "返回值"},
  usage="Script.load(path)",
  example="Script.load(File.scriptsDir() .. \"/lib_helpers.lua\")")

D("Zy.Script.scriptsDir", zh_name="脚本目录", zh_desc="同 File.scriptsDir。",
  purpose="路径。", scenario="拼路径。",
  principle="同 File。", related=["Zy.File.scriptsDir"],
  errors=[], params=[{"name": "无", "type": "—", "desc": "无", "required": False, "default": None}],
  returns={"type": "string", "desc": "目录"},
  usage="Script.scriptsDir()",
  example="Log.write(Script.scriptsDir())")

D("Zy.Script.stepState", zh_name="状态步进", zh_desc="委托 StateMachine.step。",
  purpose="简写。", scenario="同状态机。",
  principle="StateMachine.step。", related=["Zy.StateMachine.step"],
  errors=[],
  params=[{"name": "handlers", "type": "table", "desc": "handlers", "required": True, "default": None}],
  returns={"type": "同 step", "desc": ""},
  usage="Script.stepState(H)",
  example="Script.stepState({login=function() Touch.atRatio(0.64,0.72) end})")

D("Zy.Script.assertPlatform", zh_name="断言平台", zh_desc="确认在子砚环境。",
  purpose="防误跑。", scenario="库入口。",
  principle="检查 Zy/引擎。", related=["Zy.Script.begin"],
  errors=["非平台抛错"],
  params=[{"name": "无", "type": "—", "desc": "无", "required": False, "default": None}],
  returns={"type": "—", "desc": ""},
  usage="Script.assertPlatform()",
  example="Script.assertPlatform()\nScript.begin({bid=BID, design_w=1136, design_h=640})")

D("Zy.Script.generate",
  zh_name="生成脚本", zh_desc="根据自然语言需求，从 Script/Template 规则生成可运行的 Lua 脚本。",
  purpose="降低脚本起步成本；对接 AI 上下文。",
  scenario="输入「每天自动领取奖励」自动生成循环领奖脚本。",
  principle="关键词路由到 Template（login/find_color/ocr/auto_click/loop_task/state_machine），写入 scripts/generated/。",
  related=["Zy.Script.validate", "Zy.Script.run", "Zy.AI.generate"],
  errors=["模板缺失返回 false", "写文件失败"],
  params=[
    {"name": "need", "type": "string", "desc": "自然语言需求", "required": True, "default": None},
    {"name": "opts", "type": "table", "desc": "bid/design_w/design_h/out", "required": False, "default": "{}"},
  ],
  returns={"type": "boolean, string [, string]", "desc": "ok, path [, body]"},
  usage='Script.generate("每天自动领取奖励", { bid = "com.example.app" })',
  example='local ok, path = Script.generate("每天自动领取奖励", {\n  bid = "com.example.app", design_w = 1136, design_h = 640,\n})\nLog.write(tostring(path))')

D("Zy.Script.debug",
  zh_name="调试", zh_desc="采集当前执行函数、相位、设计/逻辑坐标、截图路径与最后错误并落盘。",
  purpose="定位脚本卡点。",
  scenario="tick 失败后查看 .ziyan_script_debug.txt；可选 UI.Dialog。",
  principle="读 Script 会话变量 + Screen.snapshot + Coordinate.point。",
  related=["Zy.Script.validate", "Zy.UI.show", "Zy.Verify.failReport"],
  errors=["截图失败时 screenshot 为空"],
  params=[{"name": "opts", "type": "table", "desc": "snapshot/path/dialog", "required": False, "default": "{}"}],
  returns={"type": "table", "desc": "含 fn/phase/coords/screenshot/path"},
  usage="local info = Script.debug({ snapshot = true })",
  example="Script.begin({bid=BID, design_w=1136, design_h=640})\nlocal info = Script.debug({ snapshot = true, dialog = true })\nLog.write(info.path)")

D("Zy.Script.validate",
  zh_name="校验", zh_desc="检查 Zy 核心函数是否存在，并拒绝物理 Touch.tap/Touch.click 写法。",
  purpose="写脚本前自检环境与危险代码。",
  scenario="generate 后 validate({code=body})；CI 冒烟。",
  principle="遍历 REQUIRED_FUNCS；扫描 code 字符串禁令。",
  related=["Zy.Script.generate", "Zy.Script.begin"],
  errors=["缺失模块时 ok=false"],
  params=[{"name": "opts", "type": "table", "desc": "code/require_begin", "required": False, "default": "{}"}],
  returns={"type": "boolean, table", "desc": "ok, report{missing,warnings,checks}"},
  usage='Script.validate({ code = src })',
  example='local ok, rep = Script.validate({ require_begin = false })\nassert(ok)\nlocal bad = Script.validate({ code = "Touch.tap(500,300)" })\n-- bad == false')

D("Zy.Script.sdkRoot", zh_name="SDK根路径", zh_desc="返回 Script/ 模板与 Helper 所在根目录。",
  purpose="定位用户 SDK 资源。", scenario="加载 Helper/sdk.lua。",
  principle="探测仓库路径 / Media/ZiYan/Script。", related=["Zy.Script.generate"],
  errors=[],
  params=[{"name": "无", "type": "—", "desc": "无", "required": False, "default": None}],
  returns={"type": "string", "desc": "绝对路径"},
  usage="local root = Script.sdkRoot()",
  example='Log.write(Script.sdkRoot())')

# Config / Input / Log
D("Zy.Config.path", zh_name="路径", zh_desc="配置文件绝对路径。",
  purpose="定位配置。", scenario="调试。",
  principle="Media/ZiYan/config/<name>.json。", related=["Zy.Config.load"],
  errors=[],
  params=[{"name": "name", "type": "string", "desc": "配置名", "required": False, "default": "script"}],
  returns={"type": "string", "desc": "路径"},
  usage="Config.path(\"main\")",
  example="Log.write(Config.path(\"main\"))")

D("Zy.Config.load", zh_name="加载", zh_desc="读取 JSON 配置表。",
  purpose="外置参数。", scenario="账号区服、开关。",
  principle="读文件 + json.decode。", related=["Zy.Config.save", "Zy.Config.get"],
  errors=["无文件返回 default"],
  params=[{"name": "name", "type": "string", "desc": "配置名", "required": False, "default": "script"},
          {"name": "default", "type": "table", "desc": "缺省表", "required": False, "default": "{}"}],
  returns={"type": "table", "desc": "配置"},
  usage="local cfg = Config.load(\"main\", {retry=3})",
  example="local cfg = Config.load(\"main\", {retry=3, bid=\"com.example.app\"})\nScript.set(\"bid\", cfg.bid)")

D("Zy.Config.save", zh_name="保存", zh_desc="保存配置表。",
  purpose="持久化。", scenario="UI 改完保存。",
  principle="json.encode 写盘。", related=["Zy.Config.load"],
  errors=[],
  params=[{"name": "name", "type": "string", "desc": "名", "required": True, "default": None},
          {"name": "tbl", "type": "table", "desc": "表", "required": True, "default": None}],
  returns={"type": "string", "desc": "路径"},
  usage="Config.save(\"main\", cfg)",
  example="Config.save(\"main\", {bid=\"com.example.app\", retry=3})")

D("Zy.Config.get", zh_name="取值", zh_desc="从已加载的 JSON 配置中读取单个键；缺失时返回 default。",
  purpose="简读。", scenario="读 retry。",
  principle="load 后取键。", related=["Zy.Config.set"],
  errors=[],
  params=[{"name": "name", "type": "string", "desc": "配置名", "required": True, "default": None},
          {"name": "key", "type": "string", "desc": "键", "required": True, "default": None},
          {"name": "default", "type": "any", "desc": "缺省", "required": False, "default": None}],
  returns={"type": "any", "desc": "值"},
  usage="Config.get(\"main\", \"retry\", 3)",
  example="local n = Config.get(\"main\", \"retry\", 3)")

D("Zy.Config.set", zh_name="设值", zh_desc="写单个键并保存。",
  purpose="改一项。", scenario="运行中改开关。",
  principle="load-merge-save。", related=["Zy.Config.get"],
  errors=[],
  params=[{"name": "name", "type": "string", "desc": "配置名", "required": True, "default": None},
          {"name": "key", "type": "string", "desc": "键", "required": True, "default": None},
          {"name": "value", "type": "any", "desc": "值", "required": True, "default": None}],
  returns={"type": "any", "desc": "value"},
  usage="Config.set(\"main\", \"retry\", 5)",
  example="Config.set(\"main\", \"last_phase\", Game.phase())")

D("Zy.Input.text", zh_name="输入文本", zh_desc="向当前焦点输入字符串。",
  purpose="填账号密码。", scenario="登录表单。",
  principle="inputText/inputStr。", related=["Zy.Input.typeAtRatio", "Zy.Touch.tapRatio"],
  errors=["无输入 API 返回 false"],
  params=[{"name": "str", "type": "string", "desc": "文本", "required": True, "default": None}],
  returns={"type": "boolean, string", "desc": "ok, via"},
  usage="Input.text(\"user01\")",
  example="Touch.atRatio(0.50, 0.40)  -- 点账号框\nmSleep(300)\nInput.text(\"user01\")")

D("Zy.Input.clear", zh_name="清空", zh_desc="尝试清空输入框。",
  purpose="重填前清理。", scenario="改账号。",
  principle="多次 Delete。", related=["Zy.Input.text"],
  errors=["无按键 API"],
  params=[{"name": "times", "type": "number", "desc": "删除次数", "required": False, "default": 12}],
  returns={"type": "boolean, string", "desc": "ok, via"},
  usage="Input.clear(16)",
  example="Input.clear(20)\nInput.text(\"new_user\")")

D("Zy.Input.typeAtRatio", zh_name="点比例并输入", zh_desc="先点比例焦点再输入。",
  purpose="一键填框。", scenario="账号/密码框。",
  principle="tapRatio + text。", related=["Zy.Input.text", "Zy.Touch.tapRatio"],
  errors=[],
  params=[{"name": "rx", "type": "number", "desc": "比例X", "required": True, "default": None},
          {"name": "ry", "type": "number", "desc": "比例Y", "required": True, "default": None},
          {"name": "str", "type": "string", "desc": "文本", "required": True, "default": None},
          {"name": "wait_ms", "type": "number", "desc": "点击后等待", "required": False, "default": 400}],
  returns={"type": "boolean, string", "desc": "ok, via"},
  usage="Input.typeAtRatio(0.5, 0.4, \"user01\")",
  example="Input.typeAtRatio(0.50, 0.40, \"user01\")\nInput.typeAtRatio(0.50, 0.48, \"pass123\")\nTouch.atRatio(0.64, 0.72)  -- 登录")

D("Zy.Log.write", zh_name="写日志", zh_desc="将消息输出到控制台，并可选弹出 toast 提示。",
  purpose="调试输出。", scenario="每步状态。",
  principle="print/toast。", related=["Zy.Log.dialog", "Zy.Log"],
  errors=[],
  params=[{"name": "msg", "type": "string", "desc": "内容", "required": True, "default": None},
          {"name": "ms", "type": "number", "desc": "toast 时长", "required": False, "default": 1200}],
  returns={"type": "—", "desc": ""},
  usage="Log.write(\"ok\")\nZy.Log(\"ok\")  -- 亦可函数式",
  example="Log.write(\"phase=\" .. Game.phase(), 800)")

D("Zy.Log.dialog", zh_name="对话框", zh_desc="弹出对话框提示用户；设备无 dialog API 时自动降级为 toast。",
  purpose="人工确认。", scenario="危险操作前提示。",
  principle="dialog 或 write。", related=["Zy.Log.write", "Zy.Log"],
  errors=[],
  params=[{"name": "msg", "type": "string", "desc": "文案", "required": True, "default": None},
          {"name": "timeout_s", "type": "number", "desc": "秒", "required": False, "default": 0}],
  returns={"type": "boolean, any", "desc": "ok, 返回值"},
  usage="Log.dialog(\"继续？\", 3)",
  example="Log.dialog(\"即将重启应用\", 2)\nApp.close()\nApp.launch(Script.get(\"bid\"))")

D("Zy.Log",
  zh_name="日志（可调用）", zh_desc="Log 模块可直接当函数调用，效果等同 Log.write，便于快速调试与示例。",
  purpose="最短路径输出日志。",
  scenario="示例脚本一行打印；临时调试断点。",
  principle="init.lua 对 Log 表设置 __call，转发到 write(msg, ms)。",
  related=["Zy.Log.write", "Zy.Log.dialog"],
  errors=[],
  params=[
    {"name": "msg", "type": "any", "desc": "日志内容", "required": True, "default": None},
    {"name": "ms", "type": "number", "desc": "toast 时长毫秒", "required": False, "default": 1200},
  ],
  returns={"type": "nil", "desc": "无返回"},
  usage="Zy.Log(\"ok\")\nLog.write(\"ok\")",
  example="Zy.Log(\"点击成功\", 800)\nLog.write(\"同步完成\")")

# ---------- Optimization 2.0 (7.6.2) ----------
D("Zy.Optimization.cycle",
  zh_name="闭环", zh_desc="长期优化一轮：collect→detect→classify→analyze→propose→human_confirm→apply→verify→record。",
  status="done",
  principle="默认 proposal 模式；禁止自动修改 Touch/Coordinate 等核心；须 human_confirm 才 apply；失败经 OptimizationRollback 回滚。",
  related=["Zy.Optimization.collect", "Zy.IssueClassifier.classify", "Zy.OptimizationAdvisor.advise", "Zy.OptimizationRollback.snapshot"],
  errors=["未确认则停在 proposal"],
  params=[
    {"name": "goal", "type": "string", "desc": "优化目标", "required": True, "default": None},
    {"name": "opts", "type": "table", "desc": "human_confirm/legacy/force_issue/device/light_test", "required": False, "default": None},
  ],
  returns={"type": "table", "desc": "ok/stages/proposal/version"},
  usage='Optimization.cycle("领奖优化", { human_confirm = true, device = "192.168.31.53" })',
  example='local r = Optimization.cycle("冒烟", {\n  force_issue = "phase_stuck",\n  human_confirm = true,\n  light_test = true,\n})\nprint(r.proposal and r.proposal.id, r.version)',
  scenario="生成脚本长期迭代；真机仅第二类设备")

D("Zy.Optimization.recordHistory",
  zh_name="记历史", zh_desc="写入 optimization_history.jsonl（时间/模块/问题/方案/设备/结果/版本）。",
  status="done",
  principle="Media/ZiYan/opt/optimization_history.jsonl + var 双写。",
  related=["Zy.Optimization.cycle", "Zy.Knowledge.save"],
  errors=[],
  params=[{"name": "entry", "type": "table", "desc": "history 字段表", "required": True, "default": None}],
  returns={"type": "table", "desc": "落盘行"},
  usage='Optimization.recordHistory({ module="Touch", issue="tap失败", result="PASS", device="192.168.31.53" })',
  example='Optimization.recordHistory({\n  module = "OCR", issue = "ocr_empty",\n  reason = "无文字", solution = "扩词表",\n  device = "192.168.31.166", result = "PENDING_CONFIRM",\n})',
  scenario="优化审计与长期指标")

D("Zy.Optimization.classify",
  zh_name="分类", zh_desc="委托 IssueClassifier 将 issue 归入七类。",
  status="done",
  principle="薄封装 IssueClassifier.classify。",
  related=["Zy.IssueClassifier.classify", "Zy.Optimization.detect"],
  errors=[],
  params=[{"name": "issue", "type": "table", "desc": "issue", "required": True, "default": None}],
  returns={"type": "table", "desc": "category/module/confidence"},
  usage="Optimization.classify({ type = 'ocr_empty' })",
  example='local c = Optimization.classify({ type = "phase_stuck" })\nprint(c.category, c.category_zh)',
  scenario="问题归因前分类")

D("Zy.IssueClassifier.classify",
  zh_name="问题分类", zh_desc="自动分类：函数/设备兼容/坐标/OCR/图像/脚本逻辑/性能。",
  status="done",
  principle="issue_type 映射 + 原因启发式。",
  related=["Zy.Optimization.detect", "Zy.Optimization.analyze"],
  errors=[],
  params=[{"name": "issue", "type": "table", "desc": "type/reason/module", "required": True, "default": None}],
  returns={"type": "table", "desc": "category/category_zh/confidence"},
  usage="IssueClassifier.classify(issue)",
  example='local c = IssueClassifier.classify({ type = "forbidden_coord" })\nassert(c.category == "coordinate")',
  scenario="优化闭环 classify 阶段")

D("Zy.OptimizationAdvisor.advise",
  zh_name="优化建议", zh_desc="生成 proposal；默认不改核心代码。",
  status="done",
  principle="proposal-only；CORE_PROTECTED 模块禁止自动改写。",
  related=["Zy.OptimizationAdvisor.confirm", "Zy.Optimization.propose"],
  errors=["touches_core 时仅 record"],
  params=[
    {"name": "issue", "type": "table", "desc": "问题", "required": True, "default": None},
    {"name": "analysis", "type": "table", "desc": "分析", "required": False, "default": None},
    {"name": "classification", "type": "table", "desc": "分类", "required": False, "default": None},
    {"name": "patch", "type": "table", "desc": "patch", "required": False, "default": None},
  ],
  returns={"type": "table", "desc": "proposal pending"},
  usage="local p = OptimizationAdvisor.advise(issue, analysis, cls, patch)",
  example='local p = OptimizationAdvisor.advise(issue, analysis, cls, { action = "tune" })\nOptimizationAdvisor.confirm(p.id, true)',
  scenario="人工确认前产出可审计建议")

D("Zy.OptimizationAdvisor.confirm",
  zh_name="确认建议", zh_desc="人工确认或拒绝 proposal。",
  status="done",
  principle="确认后 apply_allowed；核心保护仍不可自动改源码。",
  related=["Zy.OptimizationAdvisor.advise", "Zy.OptimizationAdvisor.canApply"],
  errors=["proposal_not_found"],
  params=[
    {"name": "proposal_id", "type": "string", "desc": "建议 ID", "required": True, "default": None},
    {"name": "accepted", "type": "boolean", "desc": "是否接受", "required": False, "default": True},
  ],
  returns={"type": "boolean,any", "desc": "结果"},
  usage="OptimizationAdvisor.confirm(p.id, true)",
  example="OptimizationAdvisor.confirm(p.id, true)",
  scenario="proposal 闸门")

D("Zy.OptimizationRollback.snapshot",
  zh_name="快照", zh_desc="优化 apply 前保存脚本/文件快照。",
  status="done",
  principle="Media/ZiYan/opt/snapshots/<id>/",
  related=["Zy.OptimizationRollback.restore", "Zy.OptimizationRollback.auto_restore_on_fail"],
  errors=[],
  params=[{"name": "meta", "type": "table", "desc": "path/reason/version", "required": False, "default": None}],
  returns={"type": "string,string,table", "desc": "id,dir,info"},
  usage='OptimizationRollback.snapshot({ path = script, reason = "pre_apply" })',
  example='local id = OptimizationRollback.snapshot({ path = path, reason = "before_tune" })',
  scenario="失败可回滚")

D("Zy.OptimizationRollback.restore",
  zh_name="回滚", zh_desc="从快照恢复文件。",
  status="done",
  principle="按 files.idx 写回原路径。",
  related=["Zy.OptimizationRollback.snapshot"],
  errors=["snapshot_missing"],
  params=[{"name": "snapshot_id", "type": "string", "desc": "快照 ID", "required": True, "default": None}],
  returns={"type": "boolean,number", "desc": "ok, n_files"},
  usage="OptimizationRollback.restore(id)",
  example="OptimizationRollback.restore(snap_id)",
  scenario="verify 失败自动/手动恢复")


def apply_complete_docs(catalog: dict) -> dict:
    """合并完整文档到 catalog，返回质量报告。"""
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    funcs = catalog.setdefault("functions", {})
    report = {
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "target_modules": sorted(TARGET),
        "enriched": [],
        "incomplete": [],
        "new_in_docs": [],
        "counts": {},
    }

    # apply explicit DOCS
    for fq, data in DOCS.items():
        ent = funcs.get(fq) or {
            "id": fq, "name": fq, "module": fq.split(".")[1], "changelog": [],
        }
        old_summary = ent.get("summary")
        for k, v in data.items():
            if k == "params" and v and v[0].get("name") == "无":
                ent["params"] = []
            else:
                ent[k] = v
        # 保证 summary 与 zh_desc 对齐，避免「说明过短」误判
        if not ent.get("summary") and ent.get("zh_desc"):
            ent["summary"] = ent["zh_desc"]
        elif ent.get("zh_desc") and len(str(ent.get("summary") or "")) < 8:
            ent["summary"] = ent["zh_desc"]
        ent["id"] = fq
        ent["name"] = fq
        # Zy.Log 可调用表：模块名仍记 Log
        parts = fq.split(".")
        ent["module"] = parts[1] if len(parts) > 1 else "Log"
        ent["status"] = data.get("status") or ent.get("status") or "active"
        ent["updated"] = now
        if old_summary and old_summary != ent.get("summary"):
            ch = ent.setdefault("changelog", [])
            ch.append({
                "date": now[:10],
                "before": str(old_summary)[:80],
                "after": str(ent.get("summary"))[:80],
                "reason": "阶段7.3 SDK文档充实",
                "test": "doc_gen",
            })
        # related as list of strings
        if "related" in data:
            ent["related"] = data["related"]
        # short_usage
        ent["short_usage"] = (data.get("usage") or "").split("\n")[0]
        funcs[fq] = ent
        report["enriched"].append(fq)

    # Config / Input auto stubs if scanned into catalog later
    for fq, ent in list(funcs.items()):
        mod = ent.get("module")
        if mod not in TARGET:
            continue
        incomplete_reasons = []
        if not ent.get("zh_name"):
            incomplete_reasons.append("缺中文名称")
        if not ent.get("zh_desc") and not ent.get("summary"):
            incomplete_reasons.append("缺功能说明")
        if not ent.get("example") or "TODO" in str(ent.get("example")) or "待完善" in str(ent.get("example")):
            incomplete_reasons.append("缺真实示例")
        if not ent.get("scenario"):
            incomplete_reasons.append("缺使用场景")
        if not ent.get("principle"):
            incomplete_reasons.append("缺实现原理")
        if not ent.get("related"):
            # try RELATED map
            key = f"{mod}.{fq.split('.')[-1]}"
            if key in RELATED:
                ent["related"] = [f"Zy.{x}" if not x.startswith("Zy.") else x for x in RELATED[key]]
            else:
                incomplete_reasons.append("缺关联函数")
        if not ent.get("returns"):
            incomplete_reasons.append("缺返回值")
        # param desc check
        for p in ent.get("params") or []:
            if not p.get("desc"):
                incomplete_reasons.append("参数缺说明")
                break
        if len(str(ent.get("summary") or "")) < 8 and len(str(ent.get("zh_desc") or "")) < 8:
            incomplete_reasons.append("说明过短")
        if incomplete_reasons:
            ent["doc_complete"] = False
            ent["doc_gaps"] = incomplete_reasons
            report["incomplete"].append({"id": fq, "gaps": incomplete_reasons})
        else:
            ent["doc_complete"] = True
            ent["doc_gaps"] = []

    # counts
    by_mod = {}
    for fq, ent in funcs.items():
        m = ent.get("module") or "?"
        if m not in TARGET:
            continue
        by_mod.setdefault(m, {"total": 0, "complete": 0})
        by_mod[m]["total"] += 1
        if ent.get("doc_complete"):
            by_mod[m]["complete"] += 1
    report["counts"] = by_mod
    report["target_total"] = sum(v["total"] for v in by_mod.values())
    report["target_complete"] = sum(v["complete"] for v in by_mod.values())
    # 本轮相对代码新增的文档（Config/Input 等）
    report["new_in_docs"] = [
        fq for fq in report["enriched"]
        if fq.startswith("Zy.Config.") or fq.startswith("Zy.Input.") or fq == "Zy.Log"
    ]
    catalog["functions"] = funcs
    catalog["doc_system"] = "7.3"
    catalog["updated"] = now
    QUALITY.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


def main():
    cat = json.loads(CATALOG.read_text(encoding="utf-8")) if CATALOG.exists() else {"functions": {}}
    report = apply_complete_docs(cat)
    CATALOG.write_text(json.dumps(cat, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("enriched", len(report["enriched"]))
    print("incomplete", len(report["incomplete"]))
    print("target_complete", report["target_complete"], "/", report["target_total"])


if __name__ == "__main__":
    main()
