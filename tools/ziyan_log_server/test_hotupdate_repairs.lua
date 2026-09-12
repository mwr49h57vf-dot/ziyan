-- Lua 5.3 behavioral regressions. All package commands and storage are synthetic.
local original_io, original_os = io, os
local files, failures, checks = {}, {}, 0
local installed, status, install_exit, rollback_exit, query_empty, state_fail
local io_failure, after_status, empty_after_install, changed_during_prepare, query_count
local runner
local function reset()
  files = {
    ["/case/current"] = "1.0\n",
    ["/case/versions/1.0/package.deb"] = "!<arch>\nold package",
    ["/candidate.deb"] = "!<arch>\nnew package",
  }
  installed, status, install_exit, rollback_exit = "1.0", "install ok installed", 0, 0
  query_empty, state_fail = false, false
  io_failure, after_status, empty_after_install, changed_during_prepare, query_count = nil, nil, false, false, 0
end
local function check(name, value)
  checks = checks + 1
  if not value then failures[#failures + 1] = name end
  print((value and "PASS " or "FAIL ") .. name)
end
io = {open=function(path, mode)
  mode = mode or "r"
  if mode:find("w") then
    if state_fail and path:find("/state", 1, true) then return nil, "synthetic ENOSPC" end
    files[path] = ""
  elseif files[path] == nil then return nil end
  local position = 1
  return {read=function(_, n)
    if type(n)=="number" then
      if position>#files[path] then return nil end
      local chunk=files[path]:sub(position,position+n-1); position=position+#chunk; return chunk
    end
    return files[path]
  end,
    write=function(_, data)
      if io_failure=="write" and path:find("/state",1,true) then return nil,"synthetic write failure" end
      files[path] = (files[path] or "") .. data; return true
    end,
    flush=function() if io_failure=="flush" and path:find("/state",1,true) then return nil end; return true end,
    close=function() if io_failure=="close" and path:find("/state",1,true) then return nil end; return true end,
    seek=function() return #files[path] end}
end}
os = setmetatable({execute=function(command)
  local output = command:match("> '([^']+)' 2>&1")
  if output and runner then
    local text, code = runner(command)
    files[output] = text
    return code==0 and true or nil, "exit", code
  end
  return true, "exit", 0
end,
  remove=function(p) files[p] = nil; return true end,
  rename=function(a,b)
    if io_failure=="rename" and b=="/case/state" then return nil,"synthetic rename failure" end
    if not files[a] then return nil end files[b]=files[a];files[a]=nil;return true
  end}, {__index=original_os})
_G.ZIYAN_HOTUPDATE_ROOT = "/case"
_G.ZIYAN_VAR = "/case"
reset()
local H = dofile("lua/modules/HotUpdate.lua")
local run_capture = H.execute
H.execute = function(command)
  if command:find("sha256",1,true) then return string.rep("a",64), 0 end
  if command:find("dpkg-deb",1,true) then
    local ver = command:find("/1.0/",1,true) and "1.0" or "2.0"
    return "com.ziyan.ziyan\n" .. ver .. "\niphoneos-arm\n", 0
  end
  if command:find("--compare-versions",1,true) then
    local left, right = command:match("versions%s+'([^']+)'%s+gt%s+'([^']+)'")
    if not left then return "", 2 end
    local relation = {["2.0:1.0"]=true,["1.0:1.0~rc1"]=true,["1.10:1.9"]=true,["2:1.0:1:99.0"]=true}
    return "", relation[left..":"..right] and 0 or 1
  end
  if command:find("dpkg-query",1,true) then
    query_count=query_count+1
    if changed_during_prepare and query_count==2 then installed="3.0" end
    if query_empty then return "", 1 end
    return status .. "\t" .. installed .. "\tiphoneos-arm", 0
  end
  if command:find("dpkg -i",1,true) then
    local rollback = command:find("/1.0/",1,true)
    local code = rollback and rollback_exit or install_exit
    if code==0 then installed=rollback and "1.0" or "2.0" end
    if rollback then
      status="install ok installed"; query_empty=false
    else
      if after_status then status=after_status end
      if empty_after_install then query_empty=true end
    end
    return "Unpacking com.ziyan.ziyan\nSetting up com.ziyan.ziyan", code
  end
  return "", 0
end
runner = H.execute
H.arch = function() return "iphoneos-arm" end

reset()
local missing_health_ok,missing_health_reason=H.install("/candidate.deb","2.0")
check("missing runtime health verifier blocks install before mutation",missing_health_ok==false and missing_health_reason=="runtime_health_required" and installed=="1.0" and files["/case/transaction"]==nil)
local function install(path,version,opts)
  opts=opts or {health_check=function() return true end}
  return H.install(path,version,opts)
end

reset(); install_exit=1; rollback_exit=1
local ok, why = install("/candidate.deb","2.0")
check("progress text with failed exit is failure", ok==false)
check("failure preserves old current pointer", H.current_version()=="1.0")
check("rollback failure is propagated", tostring(why):find("rollback_failed",1,true)~=nil)

reset(); query_empty=true
ok, why=H.health_check()
check("empty dpkg query fails health",ok==false)

reset(); status="install ok half-configured"
ok, why=H.health_check()
check("half configured package fails health",ok==false)
reset(); installed="1.0-1"
ok, why=H.health_check()
check("health requires exact version",ok==false)

reset(); installed="2.0"
ok, why=install("/candidate.deb","2.0")
check("same installed version rejected",ok==false)
reset(); installed="3.0"
ok, why=install("/candidate.deb","2.0")
check("downgrade rejected",ok==false)

reset(); state_fail=true
ok, why=install("/candidate.deb","2.0")
check("state commit failure returned",ok==false)
check("state failure rolls back installed package",installed=="1.0")

reset(); install_exit=1
ok, why=install("/candidate.deb","2.0")
check("failed install recovers old package",ok==false and installed=="1.0" and tostring(why):find("rolled_back",1,true)~=nil)

reset()
ok, why=install("/candidate.deb","2.0")
check("verified upgrade commits state",ok==true and H.current_version()=="2.0" and installed=="2.0")
ok, why=install("/candidate.deb","2.0")
check("repeated update is no update",ok==false)
ok, why=H.rollback()
check("explicit rollback verifies old package",ok==true and H.current_version()=="1.0" and installed=="1.0")

reset(); files["/case/versions/1.0/package.deb"] = nil
ok, why=install("/candidate.deb","2.0")
check("missing rollback package prevents installation",ok==false and installed=="1.0")

reset()
ok, why=install("/candidate.deb","2.0",{health_check=function() return false,"synthetic unhealthy" end})
check("runtime health failure recovers old package",ok==false and installed=="1.0" and H.current_version()=="1.0")

reset(); files["/case/transaction"]="1.0\n2.0\n"; installed="2.0"
ok, why=install("/candidate.deb","2.0")
check("interrupted transaction blocks new installation",ok==false and why=="recovery_required")
ok, why=H.rollback()
check("interrupted transaction has explicit verified recovery",ok==true and installed=="1.0" and files["/case/transaction"]==nil)

reset(); files["/case/versions/1.0/package.deb.sha256"] = string.rep("b",64)
ok, why=install("/candidate.deb","2.0")
check("tampered rollback checksum blocks installation",ok==false and installed=="1.0")

for _,stage in ipairs({"write","flush","close","rename"}) do
  reset(); io_failure=stage
  ok,why=install("/candidate.deb","2.0")
  check("state "..stage.." failure preserves committed state and rolls back",ok==false and H.current_version()=="1.0" and installed=="1.0")
end
reset(); after_status="install ok half-configured"
ok,why=install("/candidate.deb","2.0")
check("zero exit with half configured status rolls back",ok==false and installed=="1.0" and tostring(why):find("rolled_back",1,true)~=nil)
reset(); empty_after_install=true
ok,why=install("/candidate.deb","2.0")
check("empty query after zero exit rolls back",ok==false and installed=="1.0" and tostring(why):find("rolled_back",1,true)~=nil)
reset(); changed_during_prepare=true
ok,why=install("/candidate.deb","2.0")
check("version changes during preparation prevent stale install",ok==false and why=="installed_version_changed" and installed=="3.0" and files["/case/transaction"]==nil)

reset()
ok,why=install("/candidate.deb","2.0",{health_check=function() error("synthetic runtime probe exception") end})
check("runtime probe exception rolls back without committing state",ok==false and installed=="1.0" and H.current_version()=="1.0")

reset()
local saved_check,saved_download,saved_verify=H.check,H.download,H.verify
local downloaded=false
H.check=function() return {update=true,version="2.0",url="/candidate.deb"} end
H.download=function() downloaded=true;return true,"/candidate.deb" end
H.verify=function() return true end
ok,why=H.run_once("http://synthetic.test",{})
check("run_once requires runtime verifier before download",ok==false and why=="runtime_health_required" and not downloaded and installed=="1.0")
ok,why=H.run_once("http://synthetic.test",{dry_run=true})
check("dry run remains available without runtime verifier",ok==true and why=="dry_run" and not downloaded)
ok,why=H.run_once("http://synthetic.test",{verify_only=true})
check("verification only remains available without installation",ok==true and why=="verified" and downloaded and installed=="1.0")
H.check,H.download,H.verify=saved_check,saved_download,saved_verify

reset(); runner=function() return "progress is not success",7 end
local output,code=run_capture("synthetic command")
check("capture preserves command nonzero exit and output",code==7 and output=="progress is not success")

io, os = original_io, original_os
print("RESULT checks="..checks.." failures="..#failures)
if #failures>0 then os.exit(1) end
