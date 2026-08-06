-- ZiYan API contract: codec
-- 编解码
-- backend: lua/json.lua + 自研封装
-- 本文件仅为签名契约/占位，实现见 lua/ziyan_engine/；禁止引入第三方专有模块
local M = { module = 'codec', version = '1.0.0-draft' }
local function NYI(name)
  return function(...)
    error('ZiYan: API not implemented in contract stub: ' .. name, 2)
  end
end

-- jsonEncode(t) -> string  [done]
--   安全编码
-- 已实现：由 ziyan_engine 安装到 _G.jsonEncode
M.jsonEncode = _G.jsonEncode  -- 运行时绑定（契约侧只读）

-- jsonDecode(s) -> any|nil  [done]
--   空串不抛错
-- 已实现：由 ziyan_engine 安装到 _G.jsonDecode
M.jsonDecode = _G.jsonDecode  -- 运行时绑定（契约侧只读）

-- aesEncrypt(s, key) -> string  [planned]
function M.aesEncrypt(s, key)
  return NYI('aesEncrypt')(s, key)
end

-- aesDecrypt(s, key) -> string  [planned]
function M.aesDecrypt(s, key)
  return NYI('aesDecrypt')(s, key)
end

-- md5String(s) -> string  [planned]
function M.md5String(s)
  return NYI('md5String')(s)
end

-- md5File(path) -> string  [planned]
function M.md5File(path)
  return NYI('md5File')(path)
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
