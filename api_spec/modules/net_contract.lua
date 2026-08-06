-- ZiYan API contract: net
-- 网络 / FTP / 时间
-- backend: lua/ziyan_engine/py_cv.lua (curl)
-- 本文件仅为签名契约/占位，实现见 lua/ziyan_engine/；禁止引入第三方专有模块
local M = { module = 'net', version = '1.0.0-draft' }
local function NYI(name)
  return function(...)
    error('ZiYan: API not implemented in contract stub: ' .. name, 2)
  end
end

-- NetTime(timeout?) -> string  [done]
--   网络时间 YYYY-mm-dd HH:MM:SS
-- 已实现：由 ziyan_engine 安装到 _G.NetTime
M.NetTime = _G.NetTime  -- 运行时绑定（契约侧只读）

-- NetIp(timeout?) -> string  [partial]
--   外网 IP
function M.NetIp(timeout)
  return NYI('NetIp')(timeout)
end

-- httpGet(url, timeout?) -> string  [planned]
--   HTTP GET
function M.httpGet(url, timeout)
  return NYI('httpGet')(url, timeout)
end

-- FtpUpload(host, user, pass, local, remote, port?, timeout?) -> table  [done]
-- 已实现：由 ziyan_engine 安装到 _G.FtpUpload
M.FtpUpload = _G.FtpUpload  -- 运行时绑定（契约侧只读）

-- FtpDownload(host, user, pass, remote, local, port?, timeout?) -> table  [done]
-- 已实现：由 ziyan_engine 安装到 _G.FtpDownload
M.FtpDownload = _G.FtpDownload  -- 运行时绑定（契约侧只读）

-- FtpDelete(host, user, pass, remote, port?, timeout?) -> table  [done]
-- 已实现：由 ziyan_engine 安装到 _G.FtpDelete
M.FtpDelete = _G.FtpDelete  -- 运行时绑定（契约侧只读）

-- FtpRead(host, user, pass, remote, port?, timeout?) -> table  [done]
-- 已实现：由 ziyan_engine 安装到 _G.FtpRead
M.FtpRead = _G.FtpRead  -- 运行时绑定（契约侧只读）

-- FtpIsUpdate(host, user, pass, remote, local?, port?, timeout?) -> table  [done]
-- 已实现：由 ziyan_engine 安装到 _G.FtpIsUpdate
M.FtpIsUpdate = _G.FtpIsUpdate  -- 运行时绑定（契约侧只读）

function M.install_globals()
  for k, v in pairs(M) do
    if type(v) == 'function' and k ~= 'install_globals' then
      if type(_G[k]) ~= 'function' then _G[k] = v end
    end
  end
  return M
end

return M
