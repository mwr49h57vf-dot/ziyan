-- Generated bounded rewrite; source copy remains immutable.
local source = debug.getinfo(1, 'S').source:sub(2)
local root = source:match('^(.*)/rewrites/') or '.'
local run = dofile(root .. '/rewrites/bounded_adapter.lua')
return run({sample="血战优化/XZTLJH.lua", blockers={"ambiguous_dependencies", "dynamic_module_path_unresolved", "unresolved_dependencies"}, features={network=false, file=false, shell=false, opaque=false}})
