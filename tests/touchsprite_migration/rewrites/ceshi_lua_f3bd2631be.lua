-- Generated bounded rewrite; source copy remains immutable.
local source = debug.getinfo(1, 'S').source:sub(2)
local root = source:match('^(.*)/rewrites/') or '.'
local run = dofile(root .. '/rewrites/bounded_adapter.lua')
return run({sample="血战屠龙/ceshi.lua", blockers={"external_socket_dependency", "source_syntax_or_encryption_failure", "unbounded_loop_requires_stop_token", "unresolved_dependencies"}, features={network=true, file=false, shell=false, opaque=true}})
