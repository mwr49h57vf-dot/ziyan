-- ZiYan-owned JSON mapping for offline legacy scripts.
local json = require("json")

local M = {
  name = "sz",
  version = "offline-1.0.0",
  mode = "offline",
}

M.json = {
  encode = json.encode,
  decode = json.decode,
}
M.jsonEncode = M.json.encode
M.jsonDecode = M.json.decode

_G.sz = M
return M
