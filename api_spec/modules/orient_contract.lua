-- ZiYan API contract: orient
-- 坐标系 / init
-- backend: lua/ziyan_engine/orient.lua + ZiYanOrientMap.h
-- 本文件仅为签名契约/占位，实现见 lua/ziyan_engine/；禁止引入第三方专有模块
local M = { module = 'orient', version = '1.0.0-draft' }
local function NYI(name)
  return function(...)
    error('ZiYan: API not implemented in contract stub: ' .. name, 2)
  end
end

-- init(0|1|2) -> bool  [done]
--   Home 下/右/左
-- 已实现：由 ziyan_engine 安装到 _G.init
M.init = _G.init  -- 运行时绑定（契约侧只读）

-- ZiYanOrient.to_phys['x', 'y'] -> px,py  [done] 逻辑→物理
-- ZiYanOrient.to_logic['px', 'py'] -> x,y  [done] 物理→逻辑
-- ZiYanOrient.logical_size[] -> w,h  [done] 
function M.install_globals()
  for k, v in pairs(M) do
    if type(v) == 'function' and k ~= 'install_globals' then
      if type(_G[k]) ~= 'function' then _G[k] = v end
    end
  end
  return M
end

return M
