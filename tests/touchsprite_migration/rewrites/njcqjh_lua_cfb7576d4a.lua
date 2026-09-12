-- Generated bounded rewrite; source copy remains immutable.
local source = debug.getinfo(1, 'S').source:sub(2)
local root = source:match('^(.*)/rewrites/') or '.'
local run = dofile(root .. '/rewrites/bounded_adapter.lua')
return run({sample="怒剑传奇/NJCQJH.lua", blockers={"ambiguous_dependencies", "dynamic_module_path_unresolved", "host_shell_or_file_mutation", "unresolved_dependencies"}, features={network=false, file=false, shell=true, opaque=false}})
