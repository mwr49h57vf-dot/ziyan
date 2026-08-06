-- ZiYan API contract: file
-- 文件 / PLIST
-- backend: lua/ziyan_engine/{io_fs,py_cv}.lua
-- 本文件仅为签名契约/占位，实现见 lua/ziyan_engine/；禁止引入第三方专有模块
local M = { module = 'file', version = '1.0.0-draft' }
local function NYI(name)
  return function(...)
    error('ZiYan: API not implemented in contract stub: ' .. name, 2)
  end
end

-- FileExists(path) -> bool  [done]
-- 已实现：由 ziyan_engine 安装到 _G.FileExists
M.FileExists = _G.FileExists  -- 运行时绑定（契约侧只读）

-- FileCreate(path, content?, is_dir?) -> bool  [done]
-- 已实现：由 ziyan_engine 安装到 _G.FileCreate
M.FileCreate = _G.FileCreate  -- 运行时绑定（契约侧只读）

-- FileCopy(src, dst) -> bool  [done]
-- 已实现：由 ziyan_engine 安装到 _G.FileCopy
M.FileCopy = _G.FileCopy  -- 运行时绑定（契约侧只读）

-- FileDelete(path) -> bool  [done]
-- 已实现：由 ziyan_engine 安装到 _G.FileDelete
M.FileDelete = _G.FileDelete  -- 运行时绑定（契约侧只读）

-- FileMove(src, dst) -> bool  [done]
-- 已实现：由 ziyan_engine 安装到 _G.FileMove
M.FileMove = _G.FileMove  -- 运行时绑定（契约侧只读）

-- FileList(path, recursive?) -> table  [done]
-- 已实现：由 ziyan_engine 安装到 _G.FileList
M.FileList = _G.FileList  -- 运行时绑定（契约侧只读）

-- readFileString(path) -> string  [done]
-- 已实现：由 ziyan_engine 安装到 _G.readFileString
M.readFileString = _G.readFileString  -- 运行时绑定（契约侧只读）

-- writeFileString(path, content) -> bool  [done]
-- 已实现：由 ziyan_engine 安装到 _G.writeFileString
M.writeFileString = _G.writeFileString  -- 运行时绑定（契约侧只读）

-- PlistRead(path) -> table|nil  [done]
-- 已实现：由 ziyan_engine 安装到 _G.PlistRead
M.PlistRead = _G.PlistRead  -- 运行时绑定（契约侧只读）

-- PlistWrite(path, data) -> bool  [done]
-- 已实现：由 ziyan_engine 安装到 _G.PlistWrite
M.PlistWrite = _G.PlistWrite  -- 运行时绑定（契约侧只读）

function M.install_globals()
  for k, v in pairs(M) do
    if type(v) == 'function' and k ~= 'install_globals' then
      if type(_G[k]) ~= 'function' then _G[k] = v end
    end
  end
  return M
end

return M
