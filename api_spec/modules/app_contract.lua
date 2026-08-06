-- ZiYan API contract: app
-- 应用管理
-- backend: lua/ziyan_engine/app.lua
-- 本文件仅为签名契约/占位，实现见 lua/ziyan_engine/；禁止引入第三方专有模块
local M = { module = 'app', version = '1.0.0-draft' }
local function NYI(name)
  return function(...)
    error('ZiYan: API not implemented in contract stub: ' .. name, 2)
  end
end

-- appRun(bid:string) -> bool  [done]
--   启动 App，bid 作者填写
-- 已实现：由 ziyan_engine 安装到 _G.appRun
M.appRun = _G.appRun  -- 运行时绑定（契约侧只读）

-- appKill(bid:string) -> bool  [done]
--   结束 App
-- 已实现：由 ziyan_engine 安装到 _G.appKill
M.appKill = _G.appKill  -- 运行时绑定（契约侧只读）

-- appRunning(bid:string) -> bool  [partial]
--   是否在跑
function M.appRunning(bid)
  return NYI('appRunning')(bid)
end

-- frontAppBid() -> string  [planned]
--   前台 Bundle ID
function M.frontAppBid()
  return NYI('frontAppBid')()
end

-- appBundlePath(bid) -> string  [planned]
--   包路径
function M.appBundlePath(bid)
  return NYI('appBundlePath')(bid)
end

-- appDataPath(bid) -> string  [planned]
--   数据路径
function M.appDataPath(bid)
  return NYI('appDataPath')(bid)
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
