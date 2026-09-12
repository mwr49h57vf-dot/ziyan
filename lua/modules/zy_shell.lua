--[[ zy_shell — 统一命令执行正本（run_capture / shell_timeout）

  来源：ErrorReporter / OfflineQueue / HotUpdate 三处本地拷贝合并（2026-09-12 去重），
  行为逐行对齐原实现，未加新功能。三模块改为引用本文件。

  为什么必须用 os.execute + 重定向读回（跨 rootful/rootless/embed 三态）：
    · rootless 的 io.popen 走 libc → /bin/sh 缺失必死；
    · os.execute 在 embed 宿主被 ziyan_ios_system 覆盖（posix_spawn，/var/jb/bin/sh 优先），rootless 可用；
    · 统一走 sh -c 单命令调用（Mac sh=bash / iOS rootless sh 均可），避免跨平台 shell 语法差异。

  失败语义：找不到可写中转目录、或输出读不回时返回 nil。
  调用方退化值：ErrorReporter/OfflineQueue 依赖 nil 走各自退化分支；
  HotUpdate 侧 `or ""` 兜底（与去重前返回 "" 的行为一致）。
]]
local M = { name = "zy_shell", version = "1.0.0" }

local SH_PATH = "PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH "

--- 统一命令执行：命令 → 输出文本；不可用时 nil
function M.run_capture(cmd)
  local out = nil
  for _, d in ipairs({ _G.ZIYAN_VAR or "/usr/lib/ziyan/var", "/tmp",
      (_G.ZIYAN_ZYCV and (_G.ZIYAN_ZYCV .. "/tmp")) or nil,
      _G.ZIYAN_ZYCV }) do
    if d and not out then
      local f = io.open(d .. "/.zy_exec_probe", "w")
      if f then
        f:close()
        os.remove(d .. "/.zy_exec_probe")
        out = d .. "/.zy_exec_out.txt"
      end
    end
  end
  if not out then return nil end
  pcall(function()
    os.execute(SH_PATH .. "sh -c " .. "'" .. cmd:gsub("'", "'\\''") .. "' > '" .. out .. "' 2>&1")
  end)
  local f = io.open(out, "r")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  os.remove(out)
  return body
end

--- 子命令带硬超时的执行（VM 内不处理信号；内部用 sh 守护进程杀子孙）；不可用时 nil
function M.shell_timeout(cmd, seconds)
  local out = nil
  for _, d in ipairs({ _G.ZIYAN_VAR or "/usr/lib/ziyan/var", "/tmp",
      (_G.ZIYAN_ZYCV and (_G.ZIYAN_ZYCV .. "/tmp")) or nil,
      _G.ZIYAN_ZYCV }) do
    if d and not out then
      local f = io.open(d .. "/.zy_exec_probe", "w")
      if f then
        f:close()
        os.remove(d .. "/.zy_exec_probe")
        out = d .. "/.zy_exec_to.txt"
      end
    end
  end
  if not out then return nil end
  local tmo = math.max(2, tonumber(seconds) or 25)
  -- 关键：杀手 sleep 必须后台化（&），否则 shell 等它跑完，超时反而变慢
  local wrapped = string.format(
    "( ( sleep %d; pkill -P $$ 2>/dev/null; kill -9 $$ 2>/dev/null ) & WPID=$!; "
      .. "%s; EC=$?; kill -9 $WPID 2>/dev/null; wait 2>/dev/null; exit $EC )",
    tmo, cmd)
  pcall(function()
    os.execute(SH_PATH .. "sh -c " .. "'" .. wrapped:gsub("'", "'\\''") .. "' > '" .. out .. "' 2>&1")
  end)
  local f = io.open(out, "r")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  os.remove(out)
  return body
end

return M
