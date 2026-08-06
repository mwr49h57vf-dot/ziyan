--------------------------------------------------------------------------------
-- Screen
--------------------------------------------------------------------------------

function getColor(x, y)
  return _getColor(x, y)
end

function getColorRGB(x, y)
  local c = _getColor(x, y)
  if (c == -1) then
    return -1, -1, -1
  end
  r = bit32.band(bit32.rshift(c, 16), 0xff)
  g = bit32.band(bit32.rshift(c, 8), 0xff)
  b = bit32.band(c, 0xff)
  return r, g, b
end

function _findColorOne(colors, fuzzy, ltx, lty, rbx, rby)
  local t = jsonDecode(_findColor(jsonEncode(colors), fuzzy, ltx, lty, rbx, rby, false))
  if #t == 0 then
    return -1, -1
  else
    return t[1].x, t[1].y
  end
end

function findColor(color)
  return _findColorOne({color}, 100, 0, 0, -1, -1)
end

function findColorFuzzy(color, fuzzy)
  return _findColorOne({color}, fuzzy, 0, 0, -1, -1)
end

function findColorInRegion(color, ltx, lty, rbx, rby)
  return _findColorOne({color}, 100, ltx, lty, rbx, rby)
end

function findColorInRegionFuzzy(color, fuzzy, ltx, lty, rbx, rby)
  return _findColorOne({color}, fuzzy, ltx, lty, rbx, rby)
end

function findMultiColorInRegionFuzzy(colors, fuzzy, ltx, lty, rbx, rby)
  return _findColorOne(colors, fuzzy, ltx, lty, rbx, rby)
end

function findMultiColorInRegionFuzzyEx(colors, fuzzy, ltx, lty, rbx, rby)
  return jsonDecode(_findColor(jsonEncode(colors), fuzzy, ltx, lty, rbx, rby, true))
end

function findImage(path, trans)
  return _findImage(path, 100, trans or -1, 0, 0, -1, -1)
end

function findImageFuzzy(path, fuzzy, trans)
  return _findImage(path, fuzzy, trans or -1, 0, 0, -1, -1)
end

function findImageInRegion(path, ltx, lty, rbx, rby, trans)
  return _findImage(path, 100, trans or -1, ltx, lty, rbx, rby)
end

function findImageInRegionFuzzy(path, fuzzy, ltx, lty, rbx, rby, trans)
  return _findImage(path, fuzzy, trans or -1, ltx, lty, rbx, rby)
end

function snapshotScreen(path, scale)
  return _snapshot(path, 0, 0, -1, -1, scale or 100)
end

function snapshotRegion(path, ltx, lty, rbx, rby, scale)
  return _snapshot(path, ltx, lty, rbx, rby, scale or 100)
end

--------------------------------------------------------------------------------
-- Out
--------------------------------------------------------------------------------

function logDebug(any)
  local inspect = require("inspect")
  _log(type(any) == "string" and any or inspect(any))
end

function notifyMessage(any, ms)
  local inspect = require("inspect")
  _message(type(any) == "string" and any or inspect(any), ms or 1000)
end

function toast(any, ms)
  local inspect = require("inspect")
  _toast(type(any) == "string" and any or inspect(any), ms or 1000)
end

--------------------------------------------------------------------------------
-- Util
--------------------------------------------------------------------------------

function mSleep(ms)
  local socket = require("socket")
  for i = 1, math.floor(ms / 1000) do
    socket.sleep(1)
  end
  socket.sleep(ms % 1000 / 1000)
end

function jsonEncode(t)
  local json = require("json")
  return json.encode(t)
end

function jsonDecode(j)
  local json = require("json")
  return json.decode(j)
end

function plistRead(path)
  return jsonDecode(_plistRead(path))
end

function plistWrite(t, path)
  _plistWrite(jsonEncode(t), path)
end

function httpGet(url, timeout)
  local http = require("socket.http")
  http.TIMEOUT = timeout or 10
  local data = http.request(url)
  return data or ""
end

function ftpGet(remote, file, user, pass, timeout)
  local url = require("socket.url")
  local ltn12 = require("ltn12")
  local ftp = require("socket.ftp")
  ftp.TIMEOUT = timeout or 10

  local t = url.parse(remote)
  if user and user ~= "" then
    t.user = user
  end
  if pass and pass ~= "" then
    t.password = pass
  end
  t.type = "i"
  t.sink = ltn12.sink.file(io.open(file, "wb"))

  local _, err = ftp.get(t)
  return not err, err
end

function ftpPut(remote, file, user, pass, timeout)
  local url = require("socket.url")
  local ltn12 = require("ltn12")
  local ftp = require("socket.ftp")
  ftp.TIMEOUT = timeout or 10

  local t = url.parse(remote)
  if user and user ~= "" then
    t.user = user
  end
  if pass and pass ~= "" then
    t.password = pass
  end

  t.type = "i"
  t.source = ltn12.source.file(io.open(file, "rb"))

  local _, err = ftp.put(t)
  return not err, err
end

--------------------------------------------------------------------------------
-- Ocr
--------------------------------------------------------------------------------

function localOcrText(tessdata, lang, ltx, lty, rbx, rby, whitelist)
  local text, info = _localOcrText(tessdata, lang, ltx, lty, rbx, rby, whitelist or "")
  return text, jsonDecode(info)
end

function localOcrTextEx(tessdata, lang, whitelist, ...)
  local arg = {...}
  local text, info = _localOcrTextEx(tessdata, lang, whitelist, table.unpack(arg))
  return text, jsonDecode(info)
end

function fontInit(fonts)
  return _fontInit(jsonEncode(fonts))
end

function fontFindText(text, ltx, lty, rbx, rby, fuzzy)
  local t = jsonDecode(_fontFindText(text, ltx, lty, rbx, rby, false, fuzzy or 100))
  if #t == 0 then
    return -1, -1
  else
    return t[1].x, t[1].y
  end
end

function fontFindTextEx(text, ltx, lty, rbx, rby, fuzzy)
  return jsonDecode(_fontFindText(text, ltx, lty, rbx, rby, true, fuzzy or 100))
end

function fontOcrText(ltx, lty, rbx, rby, fuzzy)
  local text, info = _fontOcrText(ltx, lty, rbx, rby, fuzzy or 100)
  return text, jsonDecode(info)
end

--------------------------------------------------------------------------------
-- Image
--------------------------------------------------------------------------------

function imageFilter(path, t, fuzzy)
  return _imageFilter(path, jsonEncode(t), fuzzy or 100)
end

--------------------------------------------------------------------------------
-- Internal
--------------------------------------------------------------------------------

function scriptStop()
  os.exit()
end

--------------------------------------------------------------------------------
-- Internal
--------------------------------------------------------------------------------

function getUI()
  if (_G["UI"] ~= nil) then
    local json = require("json")
    return json.encode(UI)
  else
    return "[]"
  end
end
