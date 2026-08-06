--[[ Zy.Diagnose — 卡住时自动分析应优化哪一模块 ]]
local M = { name = "Diagnose", version = "1.0.0" }

function M.onStuck(frame, label)
  frame = frame or {}
  local detail = frame.detail or {}
  local via = tostring(detail.via or "")
  local reason, module, fix
  if via == "none" or via == "" then
    reason, module, fix = "vision_miss", "OCR/Image", "expand lexicon / tune OCR region / update color model"
  elseif via == "ocr" then
    reason, module, fix = "ocr_state_stuck", "OCR", "optimize OCR params / language / region"
  elseif via == "vision" then
    reason, module, fix = "vision_no_advance", "Vision", "update template / fuzzy / ROI"
  elseif via == "bright_control" then
    reason, module, fix = "tap_no_phase_change", "Coordinate/Touch", "fix design map / CTA ratio"
  elseif via == "app_window" or via == "front" then
    reason, module, fix = "app_not_foreground", "App", "relaunch / waitFront / window monitor"
  else
    reason, module, fix = "state_stuck:" .. tostring(frame.phase), "StateMachine", "refine classify lexicon / edges"
  end
  local Zy = _G.Zy
  local report = {
    bid = frame.bid,
    phase = frame.phase,
    label = label,
    reason = reason,
    module = module,
    fix = fix,
    shot = frame.shot,
    via = via,
  }
  if Zy and Zy.Verify and Zy.Verify.failReport then
    Zy.Verify.failReport({
      bid = frame.bid,
      phase = frame.phase,
      front = frame.front,
      reason = reason .. " label=" .. tostring(label),
      module = module,
      fix = fix,
      tag = "diagnose",
    })
  end
  if Zy and Zy.Case then
    Zy.Case.record({
      event = "stuck_diagnose",
      bid = frame.bid,
      phase = frame.phase,
      reason = reason,
      module = module,
      fix = fix,
      shot = frame.shot,
      ok = false,
    })
  end
  return report
end

return M
