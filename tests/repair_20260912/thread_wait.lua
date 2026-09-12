local Thread = dofile('lua/modules/Thread.lua')
local sleeps = {}
mSleep = function(ms) sleeps[#sleeps+1] = ms end
assert(Thread.wait(0) == true, 'main zero wait')
assert(Thread.wait(12) == true and sleeps[#sleeps] == 12, 'main sleeps')
local fired = false
Thread.setTimeout(0, function() fired = true end)
Thread.wait(0)
assert(fired, 'wait pumps timers')
local stage = 0
local co = coroutine.create(function() stage=1; Thread.wait(7); stage=2 end)
local ok, delay = coroutine.resume(co)
assert(ok and delay == 7 and stage == 1, 'coroutine yields')
assert(coroutine.resume(co) and stage == 2, 'coroutine resumes')
Zy = {Thread=Thread}
local compat = dofile('lua/ziyan_engine/compat_impl.lua')
assert(compat.call('thread.wait', 5) == true and sleeps[#sleeps] == 5, 'compat delegates')
Zy = nil
co = coroutine.create(function() compat.call('thread.wait', 9); return 'done' end)
ok, delay = coroutine.resume(co)
assert(ok and delay == 9, 'compat fallback yields')
assert(coroutine.resume(co), 'compat fallback resumes')
assert(compat.call('thread.wait', 3) == true and sleeps[#sleeps] == 3, 'compat main sleeps')
print('PASS Thread wait: main, coroutine, compat, timers')
