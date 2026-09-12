-- Shared bounded adapter for blocked TouchSprite samples.
-- It records the safe lifecycle shape without executing source-side network,
-- host-shell, direct-file, encrypted, or unbounded-loop behavior.

local ok, Zy = pcall(require, "modules.init")
local function emit(message)
  if ok and Zy and Zy.Log and type(Zy.Log.write) == "function" then
    pcall(Zy.Log.write, message)
  else
    io.write(message .. "\n")
  end
end

local function write_result(path, spec, status)
  if not path or path == "" then
    return
  end
  local file = assert(io.open(path, "w"))
  file:write("status=", status, "\n")
  file:write("sample=", spec.sample, "\n")
  file:write("rewrite=bounded\n")
  file:write("blockers=", table.concat(spec.blockers, ","), "\n")
  file:close()
end

return function(spec)
  assert(type(spec) == "table" and type(spec.sample) == "string")
  local loops = tonumber(os.getenv("ZIYAN_MIGRATION_LOOPS") or "1") or 1
  loops = math.max(0, math.min(math.floor(loops), 20))
  emit("ZIYAN_MIGRATION_REWRITE start sample=" .. spec.sample)
  emit("ZIYAN_MIGRATION_REWRITE blockers=" .. table.concat(spec.blockers, ","))
  for i = 1, loops do
    emit("ZIYAN_MIGRATION_REWRITE step=" .. i .. "/" .. loops)
    if ok and Zy and Zy.Timer and type(Zy.Timer.mSleep) == "function" then
      pcall(Zy.Timer.mSleep, 1)
    end
  end
  if spec.features.network then
    emit("ZIYAN_MIGRATION_REWRITE network=skipped_external_dependency")
  end
  if spec.features.file then
    emit("ZIYAN_MIGRATION_REWRITE file=skipped_sandbox_mapping_required")
  end
  if spec.features.shell then
    emit("ZIYAN_MIGRATION_REWRITE shell=skipped_host_mutation")
  end
  if spec.features.opaque then
    emit("ZIYAN_MIGRATION_REWRITE opaque_source=stub_only")
  end
  emit("ZIYAN_MIGRATION_REWRITE stop=bounded")
  write_result(os.getenv("ZIYAN_MIGRATION_RESULT"), spec, "completed")
  return true
end
