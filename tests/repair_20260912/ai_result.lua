package.path = 'lua/?.lua;lua/?/init.lua;' .. package.path
Zy = {Script={get=function() return false end}, File={read=function() return '' end}, Log=function() end}
package.loaded['modules._ctx'] = {}
local AI = require('modules.AI')
AI.record = function() end
local path = 'tmp_shots/repair-20260912/ai-case.lua'
local function check(body, expect, status)
  local f=assert(io.open(path,'w')); f:write('-- AI-GENERATED Zy.Script\n'..body); f:close()
  local ok,d=AI.test(path,{real_device=true})
  assert(ok==expect and d.functional_pass==expect, body..' returned '..tostring(ok))
  assert(d.status==status, 'expected '..status..' got '..tostring(d.status))
  return d
end
check('return function() return false end',false,'failed')
check('return function() return nil end',false,'unverified')
check('return function() error("fixture") end',false,'failed')
check('return function() return true end',true,'passed')
main=function() return true end
check('return {}',false,'unverified')
check('function main() return false end',false,'failed')
assert(type(main)=='function' and main()==true,'restore prior global main')
local f=assert(io.open(path,'w')); f:write('-- AI-GENERATED Zy.Script\nreturn function() return true end'); f:close()
local ok,d=AI.test(path,{real_device=true,require_capability_evidence=true})
assert(not ok and d.reason=='CAPABILITY_EVIDENCE_INCOMPLETE')
local Matrix=require('modules.TestMatrix')
Matrix.generate=function() return true,{path=path,case={case_id='fixture'}} end
Zy.AI=AI
ok,d=Matrix.run({},{real_device=true})
assert(ok and d.status=='passed')
ok,d=Matrix.run({},{real_device=true,require_capability_evidence=true})
assert(not ok and d.reason=='CAPABILITY_EVIDENCE_INCOMPLETE','matrix must forward evidence requirement')
f=assert(io.open(path,'w')); f:write('-- AI-GENERATED Zy.Script\nreturn function() return nil end'); f:close()
ok,d=Matrix.run({},{real_device=true})
assert(not ok and d.status=='unverified')
os.remove(path)
print('PASS AI.test result and matrix semantics (local fixture, not device verdict)')
