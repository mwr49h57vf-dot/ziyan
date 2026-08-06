-- ZiYan API contract: sys
-- 系统 / 提示 / 延时
-- backend: lua/ziyan_engine/{control,toast,device}.lua + SpringBoard toast bridge
-- 本文件仅为签名契约/占位，实现见 lua/ziyan_engine/；禁止引入第三方专有模块
local M = { module = 'sys', version = '1.0.0-draft' }
local function NYI(name)
  return function(...)
    error('ZiYan: API not implemented in contract stub: ' .. name, 2)
  end
end

-- mSleep(ms:number) -> void  [done]
--   延时毫秒；内含暂停/停止检查点
-- 已实现：由 ziyan_engine 安装到 _G.mSleep
M.mSleep = _G.mSleep  -- 运行时绑定（契约侧只读）

-- toast(any, ms?:number) -> void  [done]
--   非阻塞吐司
-- 已实现：由 ziyan_engine 安装到 _G.toast
M.toast = _G.toast  -- 运行时绑定（契约侧只读）

-- notifyMessage(any, ms?:number) -> void  [done]
--   消息提示（对齐 dialog 语义）
-- 已实现：由 ziyan_engine 安装到 _G.notifyMessage
M.notifyMessage = _G.notifyMessage  -- 运行时绑定（契约侧只读）

-- logDebug(any) -> void  [done]
--   调试日志
-- 已实现：由 ziyan_engine 安装到 _G.logDebug
M.logDebug = _G.logDebug  -- 运行时绑定（契约侧只读）

-- scriptStop() -> void  [done]
--   安静退出脚本
-- 已实现：由 ziyan_engine 安装到 _G.scriptStop
M.scriptStop = _G.scriptStop  -- 运行时绑定（契约侧只读）

-- notifyVibrate(ms?:number) -> bool  [planned]
--   震动
function M.notifyVibrate(ms)
  return NYI('notifyVibrate')(ms)
end

-- notifyVoice(path:string) -> bool  [planned]
--   播放提示音
function M.notifyVoice(path)
  return NYI('notifyVoice')(path)
end

-- inputText(text:string) -> bool  [partial]
--   输入文字
function M.inputText(text)
  return NYI('inputText')(text)
end

-- openURL(url:string) -> bool  [partial]
--   打开 URL / Bundle
function M.openURL(url)
  return NYI('openURL')(url)
end

-- getDeviceID() -> string  [planned]
--   设备标识
function M.getDeviceID()
  return NYI('getDeviceID')()
end

-- copyText(text:string) -> bool  [done]
--   写剪贴板
-- 已实现：由 ziyan_engine 安装到 _G.copyText
M.copyText = _G.copyText  -- 运行时绑定（契约侧只读）

-- clipText() -> string  [done]
--   读剪贴板
-- 已实现：由 ziyan_engine 安装到 _G.clipText
M.clipText = _G.clipText  -- 运行时绑定（契约侧只读）

-- deviceIsLock() -> number  [partial]
--   锁屏状态 0/1
function M.deviceIsLock()
  return NYI('deviceIsLock')()
end

-- deviceUnlock(pass?:string) -> bool  [partial]
--   解锁
function M.deviceUnlock(pass)
  return NYI('deviceUnlock')(pass)
end

-- userPath() -> string  [done]
--   脚本工程目录 Media/ZiYan
-- 已实现：由 ziyan_engine 安装到 _G.userPath
M.userPath = _G.userPath  -- 运行时绑定（契约侧只读）

-- getVersion() -> string  [partial]
--   子砚引擎版本
function M.getVersion()
  return NYI('getVersion')()
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
