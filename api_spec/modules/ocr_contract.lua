-- ZiYan API contract: ocr
-- OCR / 识字
-- backend: lua/ziyan_engine/py_cv.lua + /usr/lib/ziyan/bin/ziyan_ocr (Vision)
-- 本文件仅为签名契约/占位，实现见 lua/ziyan_engine/；禁止引入第三方专有模块
local M = { module = 'ocr', version = '1.0.0-draft' }
local function NYI(name)
  return function(...)
    error('ZiYan: API not implemented in contract stub: ' .. name, 2)
  end
end

-- getText(x, y, x1, y1) -> text, numbers  [done]
--   区域文字+数字
-- 已实现：由 ziyan_engine 安装到 _G.getText
M.getText = _G.getText  -- 运行时绑定（契约侧只读）

-- strFind(x, y, x1, y1) -> string  [done]
--   区域识字
-- 已实现：由 ziyan_engine 安装到 _G.strFind
M.strFind = _G.strFind  -- 运行时绑定（契约侧只读）

-- findStr(str, x, y, x1, y1) -> x,y  [partial]
--   找文字位置
function M.findStr(str, x, y, x1, y1)
  return NYI('findStr')(str, x, y, x1, y1)
end

-- findNumber(x, y, x1, y1) -> number|nil  [partial]
--   区域数字
function M.findNumber(x, y, x1, y1)
  return NYI('findNumber')(x, y, x1, y1)
end

-- localOcrText(tessdata, lang, x, y, x1, y1, wl?) -> string  [partial]
--   本地 tess 接口（可选）
function M.localOcrText(tessdata, lang, x, y, x1, y1, wl)
  return NYI('localOcrText')(tessdata, lang, x, y, x1, y1, wl)
end

-- cloudOcrText(user, pass, softid, x, y, x1, y1) -> string  [partial]
--   云 OCR（可选配置）
function M.cloudOcrText(user, pass, softid, x, y, x1, y1)
  return NYI('cloudOcrText')(user, pass, softid, x, y, x1, y1)
end

-- ZiYanCV.ocr_backends[] -> table  [done] 可用后端列表
-- ZiYanCV.capture_region['x', 'y', 'x1', 'y1', 'path?'] -> table  [done] 裁剪区域图
function M.install_globals()
  for k, v in pairs(M) do
    if type(v) == 'function' and k ~= 'install_globals' then
      if type(_G[k]) ~= 'function' then _G[k] = v end
    end
  end
  return M
end

return M
