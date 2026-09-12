-- Generated bounded rewrite; source copy remains immutable.
local source = debug.getinfo(1, 'S').source:sub(2)
local root = source:match('^(.*)/rewrites/') or '.'
local run = dofile(root .. '/rewrites/bounded_adapter.lua')
return run({sample="圣戒信条/SJXTJH.lua", blockers={"dynamic_module_path_unresolved", "source_syntax_or_encryption_failure", "unresolved_dependencies"}, features={network=false, file=false, shell=false, opaque=true}})
