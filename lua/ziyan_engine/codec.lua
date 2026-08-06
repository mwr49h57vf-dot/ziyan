--[[ 编解码：jsonEncode / jsonDecode（空串不抛错） ]]
local M = {}

local function defined(n) return type(_G[n]) == "function" end

function M.install()
  if not defined("jsonEncode") then
    function jsonEncode(t)
      local ok, json = pcall(require, "json")
      if not ok or not json or not json.encode then return "{}" end
      local eok, s = pcall(json.encode, t)
      return eok and s or "{}"
    end
  end

  if not defined("jsonDecode") then
    function jsonDecode(j)
      if type(j) ~= "string" or j == "" or not j:find("%S") then
        return nil
      end
      local ok, json = pcall(require, "json")
      if not ok or not json or not json.decode then return nil end
      local dok, obj = pcall(json.decode, j)
      if dok then return obj end
      return nil
    end
  end

  return M
end

return M
