-- Generated bounded rewrite; source copy remains immutable.
local source = debug.getinfo(1, 'S').source:sub(2)
local root = source:match('^(.*)/rewrites/') or '.'
local run = dofile(root .. '/rewrites/bounded_adapter.lua')
return run({sample="血战加密/XZTLJH.lua", blockers={"direct_file_io_needs_sandboxed_mapping", "dynamic_module_path_unresolved", "host_shell_or_file_mutation", "remote_ftp_dependency", "unbounded_loop_requires_stop_token", "unresolved_dependencies"}, features={network=true, file=true, shell=true, opaque=false}})
