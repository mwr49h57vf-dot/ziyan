-- ZiYan API contract: control
-- 运行控制（音量菜单协同）
-- backend: lua/ziyan_engine/control.lua + ZiYanVol tweak
-- 本文件仅为签名契约/占位，实现见 lua/ziyan_engine/；禁止引入第三方专有模块
local M = { module = 'control', version = '1.0.0-draft' }
local function NYI(name)
  return function(...)
    error('ZiYan: API not implemented in contract stub: ' .. name, 2)
  end
end

-- ziyan_pause_point() -> void  [done]
--   检查暂停/停止标志
-- 已实现：由 ziyan_engine 安装到 _G.ziyan_pause_point
M.ziyan_pause_point = _G.ziyan_pause_point  -- 运行时绑定（契约侧只读）

-- __ZIYAN_wait_while_paused() -> void  [done]
--   内部：暂停自旋
-- 已实现：由 ziyan_engine 安装到 _G.__ZIYAN_wait_while_paused
M.__ZIYAN_wait_while_paused = _G.__ZIYAN_wait_while_paused  -- 运行时绑定（契约侧只读）

function M.install_globals()
  for k, v in pairs(M) do
    if type(v) == 'function' and k ~= 'install_globals' then
      if type(_G[k]) ~= 'function' then _G[k] = v end
    end
  end
  return M
end

return M
