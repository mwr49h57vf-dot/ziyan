--[[ Script/Helper/sdk.lua
  子砚脚本 Helper：面向用户的便捷 API（委托 Zy.*）

  ============================================================================
  函数完整说明（SDK 层）
  ============================================================================

  ---------------------------------------------------------------------------
  函数：Helper.tap
  中文：点击（设计坐标）
  功能：在已设置的设计坐标系下点击一点。禁止当作物理像素使用。
  参数：
    x     number  设计 X 坐标     必填  无默认
    y     number  设计 Y 坐标     必填  无默认
    hold  number  按住毫秒        可选  默认引擎值
  返回值：boolean [, number, number]  — ok, 逻辑x, 逻辑y
  异常：未 setDesign / 管道未就绪时由 Touch 抛错或返回 false
  示例：
    Coordinate.setDesign(1136, 640)
    Helper.tap(500, 300)
  ---------------------------------------------------------------------------

  ---------------------------------------------------------------------------
  函数：Helper.tapRatio
  中文：比例点击
  功能：按屏幕宽高比例点击（0~1）。
  参数：rx number 比例X 必填；ry number 比例Y 必填；hold number 可选
  返回值：boolean [, number, number]
  示例：Helper.tapRatio(0.44, 0.72)
  ---------------------------------------------------------------------------

  ---------------------------------------------------------------------------
  函数：Helper.findColor
  中文：找色
  功能：设计区域内多点模糊找色。
  参数：同 Zy.Image.findColor
  返回值：x,y（未找到 -1,-1）
  示例：local x,y = Helper.findColor(0xE8C070, "", 90, 0,0,1136,640)
  ---------------------------------------------------------------------------

  ---------------------------------------------------------------------------
  函数：Helper.findText
  中文：找字
  功能：OCR 查找文字并返回命中坐标。
  参数：word string 必填；可选设计区域
  返回值：x,y,via
  示例：local x,y = Helper.findText("领取")
  ---------------------------------------------------------------------------
]]

local H = { name = "ScriptHelper", version = "1.0.0" }

local function Zy()
  return assert(_G.Zy, "请先 require('modules.init') 或由 ziyan_run 加载")
end

function H.tap(x, y, hold)
  return Zy().Touch.tapDesign(x, y, hold)
end

function H.tapRatio(rx, ry, hold)
  return Zy().Touch.tapRatio(rx, ry, hold)
end

function H.tapHit(lx, ly, hold)
  return Zy().Touch.tapHit(lx, ly, hold)
end

function H.findColor(...)
  return Zy().Image.findColor(...)
end

function H.findText(word, x1, y1, x2, y2)
  return Zy().OCR.find(word, x1, y1, x2, y2)
end

function H.ocr(x1, y1, x2, y2)
  return Zy().OCR.region(x1, y1, x2, y2)
end

function H.sleep(ms)
  if type(mSleep) == "function" then mSleep(ms) else
    os.execute(string.format("sleep %.3f", (tonumber(ms) or 0) / 1000))
  end
end

function H.log(msg)
  local z = Zy()
  if z.Log and z.Log.write then z.Log.write(msg) else print(tostring(msg)) end
end

-- 挂到 Zy.Script.Helper（若已加载 Script）
function H.install()
  local z = _G.Zy
  if type(z) == "table" and type(z.Script) == "table" then
    z.Script.Helper = H
  end
  _G.Helper = H
  return H
end

return H
