--[[ Zy.TestMatrix — 四机真机功能矩阵执行门面
  只负责把 API/能力案例交给 Zy.Script/Zy.AI 生成和执行。
  本模块不提供本地模拟 PASS，也不直接实现业务动作。
]]
local M = {
  name = "TestMatrix",
  version = "1.0.0",
  devices = { ".101", ".112", ".166", ".53" },
  coverage = {
    "normal", "error", "repeated", "timeout",
    "abnormal_exit", "stop_cleanup", "rootful", "rootless",
  },
}

local function copy_list(xs)
  local out = {}
  for i, value in ipairs(xs or {}) do out[i] = value end
  return out
end

function M.describe(case)
  case = case or {}
  return {
    case_id = tostring(case.case_id or case.module or "unknown"),
    module = tostring(case.module or ""),
    fn = tostring(case["function"] or case.fn or ""),
    devices = copy_list(M.devices),
    coverage = copy_list(M.coverage),
    generator = { "Zy.AI.pipeline", "Zy.Script.generateFromTask" },
    pass_source = "device_final_verdict",
    local_functional_pass = false,
  }
end

function M.validate(case)
  local d = M.describe(case)
  if d.module == "" or d.fn == "" then return false, "case_function_required" end
  if d.pass_source ~= "device_final_verdict" then return false, "device_verdict_required" end
  return true, d
end

function M.generate(case, opts)
  opts = opts or {}
  local ok, detail = M.validate(case)
  if not ok then return false, detail end
  local Zy = assert(_G.Zy, "Zy required")
  local task = string.format(
    "验证 ZiYan 函数 %s.%s：执行正常、错误、重复、超时、异常退出和停止清理场景；只使用 Zy 函数模块。",
    detail.module, detail.fn)
  local generated, path, src, plan, analysis = Zy.Script.generateFromTask(task, {
    bid = opts.bid,
    design_w = opts.design_w,
    design_h = opts.design_h,
    collect = opts.collect == true,
    name = opts.name,
  })
  if not generated then return false, path or "generation_failed" end
  return true, {
    case = detail,
    path = path,
    source = src,
    plan = plan,
    analysis = analysis,
  }
end

function M.run(case, opts)
  opts = opts or {}
  if opts.real_device ~= true then
    return false, {
      phase = "not_run",
      reason = "REAL_DEVICE_TEST_REQUIRED",
      functional_pass = false,
    }
  end
  local ok, generated = M.generate(case, opts)
  if not ok then return false, { phase = "generation_failed", reason = generated } end
  local Zy = assert(_G.Zy, "Zy required")
  local tested, detail = Zy.AI.test(generated.path, {
    real_device = true,
    light_test = false,
    load_only = false,
    goal = generated.case.case_id,
    bid = opts.bid,
  })
  detail = detail or {}
  detail.case_id = generated.case.case_id
  detail.path = generated.path
  detail.real_device = true
  detail.functional_pass = tested == true and detail.functional_pass == true
  return detail.functional_pass, detail
end

return M
