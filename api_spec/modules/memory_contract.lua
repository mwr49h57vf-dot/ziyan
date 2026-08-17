-- ZiYan API contract: memory
-- 内存缓存 / Hook 读名（自研，非 TE）
-- backend: lua/ziyan_engine/py_cv.lua + ziyan_mem / AppTouch MemHook
-- 本文件仅为签名契约/占位，实现见 lua/ziyan_engine/；禁止引入第三方专有模块
local M = { module = 'memory', version = '1.0.0-draft' }
local function NYI(name)
  return function(...)
    error('ZiYan: API not implemented in contract stub: ' .. name, 2)
  end
end

-- MemoryAccess(bid, key) -> string  [done]
--   优先读项目自身 JSON 缓存（兼容读取历史 plist）
-- 已实现：由 ziyan_engine 安装到 _G.MemoryAccess
M.MemoryAccess = _G.MemoryAccess  -- 运行时绑定（契约侧只读）

-- MemoryWrite(bid, key, value) -> bool  [done]
--   原子写项目自身 JSON 缓存
-- 已实现：由 ziyan_engine 安装到 _G.MemoryWrite
M.MemoryWrite = _G.MemoryWrite  -- 运行时绑定（契约侧只读）

-- MemoryKeys(bid) -> table  [done]
-- 已实现：由 ziyan_engine 安装到 _G.MemoryKeys
M.MemoryKeys = _G.MemoryKeys  -- 运行时绑定（契约侧只读）

-- MemoryDump(bid, max?) -> table  [done]
-- 已实现：由 ziyan_engine 安装到 _G.MemoryDump
M.MemoryDump = _G.MemoryDump  -- 运行时绑定（契约侧只读）

-- MemoryFind(bid, query) -> table  [partial]
--   角色/排行榜/背包等
function M.MemoryFind(bid, query)
  return NYI('MemoryFind')(bid, query)
end

-- MemoryRoleName(bid, hint?) -> string  [partial]
function M.MemoryRoleName(bid, hint)
  return NYI('MemoryRoleName')(bid, hint)
end

-- MemoryScanNames(bid) -> table  [partial]
function M.MemoryScanNames(bid)
  return NYI('MemoryScanNames')(bid)
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
