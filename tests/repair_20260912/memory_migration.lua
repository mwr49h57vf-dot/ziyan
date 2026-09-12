package.path='lua/?.lua;'..package.path
ZIYAN_VAR='tmp_shots/repair-20260912/memory'
ZIYAN_ZYCV=ZIYAN_VAR
local function put(path,body) local f=assert(io.open(path,'wb')); assert(f:write(body)); assert(f:close()) end
local function exists(path) local f=io.open(path,'rb'); if f then f:close(); return true end return false end
os.execute=function() return nil,'exit',1 end -- native helper boundary, no device shell
os.remove(ZIYAN_VAR..'/memory/new.json') -- fixture owned by this test
local cv=dofile('lua/ziyan_engine/py_cv.lua'); cv.install()
put(ZIYAN_VAR..'/memory/A.plist','valid plist fixture')
put(ZIYAN_VAR..'/memory/B.plist','corrupt plist fixture')
put(ZIYAN_VAR..'/.ziyan_mem_cache.json','{"secret":"A only"}')
PlistRead=function(path) if path:match('A.plist$') then return {secret='A only'} end return nil end
assert(MemoryAccess('A','secret')=='A only')
local value,err=MemoryAccess('B','secret')
assert(value==nil and err=='memory_plist_invalid','corrupt B must not return A or empty success')
assert(not MemoryWrite('B','new','value'),'cannot shadow broken B')
assert(not exists(ZIYAN_VAR..'/memory/B.json'))
assert(MemoryKeys('B').ok==false and MemoryDump('B').ok==false and MemoryScanNames('B').ok==false)
put(ZIYAN_VAR..'/memory/C.json','broken')
assert(not MemoryWrite('C','key','value'),'corrupt JSON stays untouched')
put(ZIYAN_VAR..'/memory/D.json','{"saved":"yes"}')
assert(MemoryAccess('D','saved')=='yes')
assert(MemoryKeys('missing').ok and #MemoryKeys('missing').keys==0)
assert(MemoryWrite('new','key','value'))
assert(MemoryAccess('new','key')=='value')
local realRename=os.rename
os.rename=function() return nil,'injected' end
assert(not MemoryWrite('D','saved','no'),'rename failure propagated')
os.rename=realRename
assert(MemoryAccess('D','saved')=='yes')
print('PASS memory migration: isolation, corruption, write guard, existing JSON, rename failure')
