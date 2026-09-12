--[[ zy_shell — 统一命令执行正本（run_capture / shell_timeout）

  来源：ErrorReporter / OfflineQueue / HotUpdate 三处本地拷贝合并（2026-09-12 去重），
  行为逐行对齐原实现，未加新功能。三模块改为引用本文件。

  为什么必须用 os.execute + 重定向读回（跨 rootful/rootless/embed 三态）：
    · rootless 的 io.popen 走 libc → /bin/sh 缺失必死；
    · os.execute 在 embed 宿主被 ziyan_ios_system 覆盖（posix_spawn，/var/jb/bin/sh 优先），rootless 可用；
    · 统一走 sh -c 单命令调用（Mac sh=bash / iOS rootless sh 均可），避免跨平台 shell 语法差异。

  失败语义：找不到可写中转目录、或输出读不回时返回 nil（退出码 1）。
  调用方退化值：ErrorReporter/OfflineQueue 依赖 nil 走各自退化分支；
  HotUpdate 侧 `or ""` 兜底（与去重前返回 "" 的行为一致）。

  退出码（2026-09-12 合并 develop 时新增，兼容增量）：
    HotUpdate 的 shasum 依赖退出码判断 sha256sum/shasum/openssl 三路兜底是否成功，
    故另开 *_status 入口返回第二值退出码；run_capture/shell_timeout 保持单返回值不变，
    已验收的调用方语义不动。
]]
local M = { name = "zy_shell", version = "1.1.0" }

local SH_PATH = "PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH "

--- 选定可写中转目录下的目标文件名；全部不可写时返回 nil
local function scratch(name)
  for _, d in ipairs({ _G.ZIYAN_VAR or "/usr/lib/ziyan/var", "/tmp",
      (_G.ZIYAN_ZYCV and (_G.ZIYAN_ZYCV .. "/tmp")) or nil,
      _G.ZIYAN_ZYCV }) do
    if d then
      local f = io.open(d .. "/.zy_exec_probe", "w")
      if f then
        f:close()
        os.remove(d .. "/.zy_exec_probe")
        return d .. "/" .. name
      end
    end
  end
  return nil
end

--- os.execute 返回值 → 退出码（5.1 返回数字；5.3 返回 ok, "exit"|"signal", code）
local function exit_code(called, ok, kind, code)
  if not called then return 1 end
  if type(ok) == "number" then return ok == 0 and 0 or ok end
  if ok == true then return 0 end
  return tonumber(code) or 1
end

--- 跑一条 sh -c 命令并把 stdout/stderr 读回；返回 输出文本, 退出码；不可用时 nil, 1
local function execute(command, name)
  local out = scratch(name)
  if not out then return nil, 1 end
  local called, ok, kind, code = pcall(os.execute,
    SH_PATH .. "sh -c " .. "'" .. command:gsub("'", "'\\''") .. "' > '" .. out .. "' 2>&1")
  local f = io.open(out, "r")
  if not f then return nil, exit_code(called, ok, kind, code) end
  local body = f:read("*a")
  f:close()
  os.remove(out)
  return body, exit_code(called, ok, kind, code)
end

--- 统一命令执行：命令 → 输出文本, 退出码；不可用时 nil, 1
function M.run_capture_status(cmd)
  return execute(cmd, ".zy_exec_out.txt")
end

--- 子命令带硬超时的执行（VM 内不处理信号；内部用 sh 守护进程杀子孙）；不可用时 nil, 1
function M.shell_timeout_status(cmd, seconds)
  local tmo = math.max(2, tonumber(seconds) or 25)
  -- 关键：杀手 sleep 必须后台化（&），否则 shell 等它跑完，超时反而变慢
  local wrapped = string.format(
    "( ( sleep %d; pkill -P $$ 2>/dev/null; kill -9 $$ 2>/dev/null ) & WPID=$!; "
      .. "%s; EC=$?; kill -9 $WPID 2>/dev/null; wait 2>/dev/null; exit $EC )",
    tmo, cmd)
  return execute(wrapped, ".zy_exec_to.txt")
end

--- 去重前语义入口：命令 → 输出文本；不可用时 nil（只返回第一个值）
function M.run_capture(cmd)
  local body = M.run_capture_status(cmd)
  return body
end

--- 去重前语义入口：带硬超时的命令 → 输出文本；不可用时 nil（只返回第一个值）
function M.shell_timeout(cmd, seconds)
  local body = M.shell_timeout_status(cmd, seconds)
  return body
end

return M
