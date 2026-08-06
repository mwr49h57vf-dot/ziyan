-- ZiYan api_spec index (load contracts only; do not load cracked telib)
local ROOT = ...
if type(ROOT) ~= 'string' or ROOT == '' then
  ROOT = '/usr/lib/ziyan/modules/api_spec'  -- 装机后可选路径；开发期用仓库相对路径
end
local order = {
  'sys',
  'touch',
  'screen',
  'image',
  'ocr',
  'app',
  'file',
  'net',
  'codec',
  'memory',
  'control',
  'orient',
  'script_sdk',
  'optimization',
}
local M = { modules = {} }
for _, name in ipairs(order) do
  local path = ROOT .. '/modules/' .. name .. '_contract.lua'
  local ok, mod = pcall(dofile, path)
  if ok then M.modules[name] = mod end
end
return M
