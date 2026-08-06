-- ZiYan API contract: image
-- 找图 / 图像处理
-- backend: lua/ziyan_engine/{cv,py_cv}.lua + ScreenBridge findImage
-- 本文件仅为签名契约/占位，实现见 lua/ziyan_engine/；禁止引入第三方专有模块
local M = { module = 'image', version = '1.0.0-draft' }
local function NYI(name)
  return function(...)
    error('ZiYan: API not implemented in contract stub: ' .. name, 2)
  end
end

-- findImage(path, trans?) -> x,y  [partial]
--   全屏找图
function M.findImage(path, trans)
  return NYI('findImage')(path, trans)
end

-- findImageFuzzy(path, fuzzy, trans?) -> x,y  [partial]
--   全屏+精度
function M.findImageFuzzy(path, fuzzy, trans)
  return NYI('findImageFuzzy')(path, fuzzy, trans)
end

-- findImageInRegion(path, x1, y1, x2, y2, trans?) -> x,y  [partial]
--   区域找图
function M.findImageInRegion(path, x1, y1, x2, y2, trans)
  return NYI('findImageInRegion')(path, x1, y1, x2, y2, trans)
end

-- findImageInRegionFuzzy(path, fuzzy, x1, y1, x2, y2, trans?) -> x,y  [done]
--   区域+精度
-- 已实现：由 ziyan_engine 安装到 _G.findImageInRegionFuzzy
M.findImageInRegionFuzzy = _G.findImageInRegionFuzzy  -- 运行时绑定（契约侧只读）

-- imageWidth(path) -> number  [planned]
--   图宽
function M.imageWidth(path)
  return NYI('imageWidth')(path)
end

-- imageHeight(path) -> number  [planned]
--   图高
function M.imageHeight(path)
  return NYI('imageHeight')(path)
end

-- imageFilter(path, colors, fuzzy?) -> bool  [planned]
--   颜色过滤
function M.imageFilter(path, colors, fuzzy)
  return NYI('imageFilter')(path, colors, fuzzy)
end

-- imageBinarization(path, threshold) -> bool  [planned]
--   二值化
function M.imageBinarization(path, threshold)
  return NYI('imageBinarization')(path, threshold)
end

-- imageResize(path, w, h) -> bool  [planned]
--   缩放
function M.imageResize(path, w, h)
  return NYI('imageResize')(path, w, h)
end

function M.install_globals()
  for k, v in pairs(M) do
    if type(v) == 'function' and k ~= 'install_globals' then
      if type(_G[k]) ~= 'function' then _G[k] = v end
    end
  end
  return M
end

return M
