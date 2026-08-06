-- Script SDK contract (阶段 7.35)
-- 实现：lua/modules/Script.lua · 用户层：Script/{Template,Examples,Helper,Debug}
local M = {
  name = "script_sdk",
  version = "1.0.0",
  status = "done",
  notes = "用户脚本 SDK：generate/debug/validate + Template；坐标禁止物理裸点",
}

M.apis = {
  {
    name = "Script.generate",
    zh = "生成脚本",
    status = "done",
    params = {
      { name = "need", type = "string", required = true, desc = "自然语言需求" },
      { name = "opts", type = "table", required = false, desc = "bid/design_w/design_h/out" },
    },
    returns = { type = "boolean, string, string?", desc = "ok, path, body" },
    example = 'Script.generate("每天自动领取奖励", { bid = "com.example.app" })',
  },
  {
    name = "Script.debug",
    zh = "调试快照",
    status = "done",
    params = {
      { name = "opts", type = "table", required = false, desc = "snapshot/path/dialog" },
    },
    returns = { type = "table", desc = "fn/phase/coords/screenshot/error" },
    example = "local info = Script.debug({ snapshot = true, dialog = true })",
  },
  {
    name = "Script.validate",
    zh = "校验脚本环境",
    status = "done",
    params = {
      { name = "opts", type = "table", required = false, desc = "code/require_begin" },
    },
    returns = { type = "boolean, table", desc = "ok, report" },
    example = 'Script.validate({ code = src })',
  },
  {
    name = "Helper.tap",
    zh = "设计坐标点击",
    status = "done",
    params = {
      { name = "x", type = "number", required = true, desc = "设计X（非物理像素）" },
      { name = "y", type = "number", required = true, desc = "设计Y" },
      { name = "hold", type = "number", required = false, default = nil, desc = "按住毫秒" },
    },
    returns = { type = "boolean, ...", desc = "同 Touch.tapDesign" },
    example = "Coordinate.setDesign(1136,640)\nHelper.tap(500,300)",
    note = "禁止当作物理 Touch.click(500,300)；须先 setDesign",
  },
}

return M
