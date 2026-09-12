package.path='lua/?.lua;'..package.path
local files={['fixture-report']='{"event_id":"zye_event"}'}
local fault,serial=nil,0
ZIYAN_VAR='/sandbox/var'; ZIYAN_ZYCV='/sandbox/zycv'
local function matches(path) return fault and path:find(fault.target,1,true) end
io.open=function(path,mode)
  local writing=mode and (mode:find('w') or mode:find('a'))
  if matches(path) and fault.stage=='open' then return nil,'injected open',13 end
  if not writing and files[path]==nil then return nil,'missing',2 end
  if writing then files[path]='' end
  return {
    write=function(self,body) if matches(path) and fault.stage=='write' then return nil,'injected write' end files[path]=(files[path] or '')..body; return self end,
    close=function() if matches(path) and fault.stage=='close' then return nil,'injected close' end return true end,
    read=function() return files[path] end,
  }
end
os.tmpname=function() serial=serial+1; return '/sandbox/tmp-'..serial end
os.rename=function(src,dst) if matches(dst) and fault.stage=='rename' then return nil,'injected rename' end files[dst]=files[src]; files[src]=nil; return true end
os.remove=function(path) files[path]=nil; return true end
os.execute=function(cmd)
  local deleting=cmd:match("rm %-rf '([^']+)'")
  if deleting then
    for path in pairs(files) do if path:sub(1,#deleting+1)==deleting..'/' then files[path]=nil end end
  end
  local out=cmd:match("> '([^']+)' 2>&1$")
  if out then
    local names={}
    if cmd:find('ls -1',1,true) then
      local dir=cmd:match("ls %-1 '([^']+)'")
      local seen={}
      for path in pairs(files) do
        if path:sub(1,#dir+1)==dir..'/' then local id=path:sub(#dir+2):match('^([^/]+)/'); if id and not seen[id] then names[#names+1]=id; seen[id]=true end end
      end
    end
    files[out]=table.concat(names,'\n')
  end
  return true,'exit',0
end
local function loadQueue() return dofile('lua/modules/OfflineQueue.lua') end
for _,stage in ipairs({'open','write','close','rename'}) do
  for _,target in ipairs({'report.json','state.json'}) do
    local q=loadQueue(); fault={stage=stage,target=target}
    assert(q.enqueue('zye_'..stage..target:gsub('%.',''),'fixture-report')==false,stage..' '..target..' must fail')
    assert(files['fixture-report'],'source retained')
  end
end
fault=nil
local q=loadQueue(); assert(q.enqueue('zye_ok','fixture-report'))
assert(q.pending_count()>=1)
local dir=q.spool_dir()..'/zye_orphan'
files[dir..'/report.json']=files['fixture-report']
Zy={Network={httpPost=function() return true,'{"ok":true}' end}}
q=loadQueue()
local stats=q.flush({force=true,batch=100})
assert(stats.sent>=2,'restart recovers orphan report')
assert(q.is_durable('zye_orphan','fixture-report'),'durable handoff query')
assert(not q.enqueue('../escape','fixture-report'),'reject invalid event path')
OfflineQueue=q
local ER=dofile('lua/modules/ErrorReporter.lua')
local _,_,handoff=ER.report('fixture','message')
assert(handoff and handoff.queued and handoff.queue_error==nil, 'successful handoff has no error')
fault={stage='open',target='state.json'}
local _,_,failed=ER.report('fixture','second message')
assert(failed and not failed.queued and failed.queue_error, 'failed handoff exposed')
fault=nil
assert(q.enqueue('zye_storage_success','fixture-report'))
fault={stage='rename',target='state.json'}
local stateFailure=q.flush({force=true,batch=100})
assert((stateFailure.storage_errors or 0)>0 and stateFailure.last_storage_error=='state_commit_failed', 'successful upload with failed state commit exposed')
fault=nil
assert(q.enqueue('zye_storage_offline','fixture-report'))
Zy.Network.httpPost=function() return false,'offline' end
fault={stage='close',target='state.json'}
stateFailure=q.flush({force=true,batch=100})
assert((stateFailure.storage_errors or 0)>0 and stateFailure.last_storage_error=='state_commit_failed', 'offline retry with failed state commit exposed')
fault=nil
local old=q.report_dir()..'/zye_1_old/report.json'
files[old]='{"event_id":"zye_1_old","time_unix":1}'
ER.purge(1)
assert(files[old], 'retention preserves report before durable handoff')
assert(q.enqueue('zye_1_old',old))
ER.purge(1)
assert(not files[old], 'retention removes only handed-off source')
assert(files[q.spool_dir()..'/zye_1_old/report.json'], 'queue keeps pending copy')
print('PASS queue open/write/close/rename faults, orphan recovery, durable handoff')
