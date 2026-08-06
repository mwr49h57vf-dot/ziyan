--[[ Learning 学习优化（子砚自研）
  采集运行数据 → 知识库 → 供 Game/codegen 使用。非 TouchSprite。
]]
local M = { module = "learning", version = "1.0.0" }

local function var_dir()
  if type(_G.ZIYAN_VAR) == "string" and #_G.ZIYAN_VAR > 0 then
    return _G.ZIYAN_VAR
  end
  if io.open("/var/jb/usr/lib/ziyan/var", "r") then
    return "/var/jb/usr/lib/ziyan/var"
  end
  return "/usr/lib/ziyan/var"
end

local function kb_path()
  return var_dir() .. "/.ziyan_knowledge.jsonl"
end

local function err_path()
  return var_dir() .. "/.ziyan_error_db.jsonl"
end

--- 追加一条知识（一行 JSON 风格简易记录）
function M.record(event)
  event = event or {}
  local line = string.format(
    '{"ts":%d,"bid":%q,"state":%q,"action":%q,"ok":%s,"x":%s,"y":%s,"detail":%q}\n',
    os.time(),
    tostring(event.bid or ""),
    tostring(event.state or ""),
    tostring(event.action or ""),
    event.ok and "true" or "false",
    tostring(event.x or -1),
    tostring(event.y or -1),
    tostring(event.detail or ""):sub(1, 120))
  pcall(function()
    local f = io.open(kb_path(), "a")
    if f then f:write(line); f:close() end
  end)
  return true
end

function M.record_error(err)
  err = err or {}
  local line = string.format(
    '{"ts":%d,"type":%q,"module":%q,"cause":%q,"fix":%q}\n',
    os.time(),
    tostring(err.type or "unknown"),
    tostring(err.module or ""),
    tostring(err.cause or ""),
    tostring(err.fix or ""):sub(1, 160))
  pcall(function()
    local f = io.open(err_path(), "a")
    if f then f:write(line); f:close() end
  end)
  return true
end

function M.paths()
  return { knowledge = kb_path(), errors = err_path() }
end

function M.install(engine)
  _G.learnRecord = function(ev) return M.record(ev) end
  _G.learnError = function(err) return M.record_error(err) end
  _G.learnPaths = function() return M.paths() end
  -- 桥接 Game：若已装 gameRemember/codegen，则 learn/codegen 指向同一闭环
  if type(_G.learn) ~= "function" and type(_G.gameRemember) == "function" then
    _G.learn = function(label, x, y, via, bid)
      return _G.gameRemember(label, x, y, via, bid)
    end
  end
  if type(_G.codegen) ~= "function" and type(_G.gameCodegen) == "function" then
    _G.codegen = function(bid) return _G.gameCodegen(bid) end
  end
  _G.ZiYanLearning = M
  if engine then engine.learning = M end
  return M
end

return M
