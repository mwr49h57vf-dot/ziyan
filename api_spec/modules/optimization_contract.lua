-- Optimization 2.0 + companions contract (阶段 7.6.2)
local M = {
  name = "optimization",
  version = "2.0.0",
  status = "done",
  notes = "LongTermOptLoop 2.0：history/classify/advisor(proposal)/rollback；默认禁止自动改核心",
}

M.apis = {
  {
    name = "Optimization.cycle",
    zh = "闭环",
    status = "done",
    params = {
      { name = "goal", type = "string", required = true },
      { name = "opts", type = "table", required = false,
        desc = "human_confirm/legacy/force_issue/device/light_test" },
    },
    returns = { type = "table", desc = "ok/stages/proposal/version；默认停在 proposal" },
    example = 'Optimization.cycle("领奖", { force_issue = "phase_stuck", human_confirm = true, device = "192.168.31.53" })',
    note = "默认 proposal；须 human_confirm 或 legacy=true 才 apply",
  },
  {
    name = "Optimization.recordHistory",
    zh = "记历史",
    status = "done",
    params = {
      { name = "entry", type = "table", required = true,
        desc = "time/module/issue/reason/solution/device/result/version" },
    },
    returns = { type = "table", desc = "写入的行" },
    example = 'Optimization.recordHistory({ module = "Touch", issue = "tap失败", result = "PASS", device = "192.168.31.53" })',
  },
  {
    name = "Optimization.classify",
    zh = "分类",
    status = "done",
    params = { { name = "issue", type = "table", required = true } },
    returns = { type = "table", desc = "category/module/confidence" },
    example = "Optimization.classify({ type = 'ocr_empty' })",
  },
  {
    name = "IssueClassifier.classify",
    zh = "问题分类",
    status = "done",
    params = { { name = "issue", type = "table", required = true } },
    returns = { type = "table", desc = "七类之一" },
    example = 'IssueClassifier.classify({ type = "forbidden_coord" })',
  },
  {
    name = "OptimizationAdvisor.advise",
    zh = "优化建议",
    status = "done",
    params = {
      { name = "issue", type = "table", required = true },
      { name = "analysis", type = "table", required = false },
      { name = "classification", type = "table", required = false },
      { name = "patch", type = "table", required = false },
    },
    returns = { type = "table", desc = "proposal（pending）" },
    example = "local p = OptimizationAdvisor.advise(issue, analysis, cls, patch)",
    note = "禁止自动修改 Touch/Coordinate 等核心模块",
  },
  {
    name = "OptimizationAdvisor.confirm",
    zh = "确认建议",
    status = "done",
    params = {
      { name = "proposal_id", type = "string", required = true },
      { name = "accepted", type = "boolean", required = false, default = true },
    },
    returns = { type = "boolean, any", desc = "是否确认成功" },
    example = "OptimizationAdvisor.confirm(p.id, true)",
  },
  {
    name = "OptimizationRollback.snapshot",
    zh = "快照",
    status = "done",
    params = {
      { name = "meta", type = "table", required = false, desc = "path/reason/version/goal" },
    },
    returns = { type = "string, string, table", desc = "id, dir, info" },
    example = 'OptimizationRollback.snapshot({ path = script_path, reason = "pre_apply" })',
  },
  {
    name = "OptimizationRollback.restore",
    zh = "回滚",
    status = "done",
    params = { { name = "snapshot_id", type = "string", required = true } },
    returns = { type = "boolean, number", desc = "ok, restored_file_count" },
    example = "OptimizationRollback.restore(snap_id)",
  },
}

return M
