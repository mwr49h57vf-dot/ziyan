-- ZiYan API contract: touch
-- 触控 / 按键
-- backend: lua/ziyan_engine/touch.lua + AppTouch / ScreenBridge HID
-- 本文件仅为签名契约/占位，实现见 lua/ziyan_engine/；禁止引入第三方专有模块
local M = { module = 'touch', version = '1.0.0-draft' }
local function NYI(name)
  return function(...)
    error('ZiYan: API not implemented in contract stub: ' .. name, 2)
  end
end

-- touchDown(finger?:number, x:number, y:number) -> bool  [done]
--   按下；支持 touchDown(x,y)
-- 已实现：由 ziyan_engine 安装到 _G.touchDown
M.touchDown = _G.touchDown  -- 运行时绑定（契约侧只读）

-- touchMove(finger?:number, x:number, y:number) -> bool  [done]
--   移动
-- 已实现：由 ziyan_engine 安装到 _G.touchMove
M.touchMove = _G.touchMove  -- 运行时绑定（契约侧只读）

-- touchUp(finger?:number, x?:number, y?:number) -> bool  [done]
--   抬起
-- 已实现：由 ziyan_engine 安装到 _G.touchUp
M.touchUp = _G.touchUp  -- 运行时绑定（契约侧只读）

-- tap(x, y [, holdMs]) / tap(finger, x, y [, holdMs]) -> bool  [done]
--   未指定手指时随机 1..9；真人按下→微移→抬起
-- 已实现：由 ziyan_engine 安装到 _G.tap
M.tap = _G.tap  -- 运行时绑定（契约侧只读）

-- swipe(x1, y1, x2, y2, ms?:number) -> bool  [done]
--   滑动
-- 已实现：由 ziyan_engine 安装到 _G.swipe
M.swipe = _G.swipe  -- 运行时绑定（契约侧只读）

-- keyDown(code:number|string) -> bool  [planned]
--   按键按下
function M.keyDown(code)
  return NYI('keyDown')(code)
end

-- keyUp(code:number|string) -> bool  [planned]
--   按键抬起
function M.keyUp(code)
  return NYI('keyUp')(code)
end

-- pressHomeKey(times?:number) -> bool  [partial]
--   Home
function M.pressHomeKey(times)
  return NYI('pressHomeKey')(times)
end

function M.install_globals()
  for k, v in pairs(M) do
    if type(v) == 'function' and k ~= 'install_globals' then
      if type(_G[k]) ~= 'function' then _G[k] = v end
    end
  end
  return M
end

return M
