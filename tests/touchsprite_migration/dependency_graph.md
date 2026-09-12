# E48 TouchSprite to ZiYan Dependency and Semantics Map

Generated from verified `sample_mapping.json`; source analysis is static and does not prove runtime compatibility.

## `赤沙龙城/CSLCJH.lua`
- entry: `top_level_bootstrap`
- status: `unmigratable_static_only`
- requires: `TSLib, ts`
- dynamic requires: `DXMC.."HS", DXMC.."UI"`
- dependency status: `dynamic_and_static_unresolved`
- resolved: `赤沙龙城/TSLib.lua`
- unresolved: `ts`
- cycle: `False`
- API mapping: none
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": false}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}
- gaps: `dynamic_module_path_unresolved`

## `赤沙龙城/TSLib.lua`
- entry: `library_or_unresolved`
- status: `dependency_only_or_no_allowlisted_api`
- requires: `none`
- dynamic requires: `none`
- dependency status: `resolved_or_external`
- resolved: `none`
- unresolved: `none`
- cycle: `False`
- API mapping: none
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": false}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}

## `赤沙龙城加密/BBH.lua`
- entry: `library_or_unresolved`
- status: `dependency_only_or_no_allowlisted_api`
- requires: `none`
- dynamic requires: `none`
- dependency status: `resolved_or_external`
- resolved: `none`
- unresolved: `none`
- cycle: `False`
- API mapping: none
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": false}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}

## `赤沙龙城加密/CSLCJH.lua`
- entry: `top_level_bootstrap`
- status: `partial_mapping_requires_rewrite`
- requires: `ts`
- dynamic requires: `(""..string.char(84)..string.char(83)..string.char(76)..string.char(105)..string.char(98)..""), DXMC.."HS", DXMC.."UI"`
- dependency status: `dynamic_and_static_unresolved`
- resolved: `none`
- unresolved: `ts`
- cycle: `False`
- API mapping: `mSleep` -> `sys.mSleep`, `closeApp` -> `app.appKill`, `setWifiEnable` -> `device.setWifiEnable`, `getNetIP` -> `net.getNetIP`
- stop: {"closeApp": true, "lua_exit": false, "unboundedLoop": true}
- cleanup: {"directFileIo": true, "remoteFtp": true, "shellMutation": true}
- gaps: `direct_file_io_needs_sandboxed_mapping`, `dynamic_module_path_unresolved`, `host_shell_or_file_mutation`, `remote_ftp_dependency`, `unbounded_loop_requires_stop_token`

## `龙界争霸/LJZBQS.lua`
- entry: `top_level_bootstrap`
- status: `direct_api_mapping`
- requires: `TSLib, sz, ts`
- dynamic requires: `none`
- dependency status: `static_ambiguous`
- resolved: `none`
- unresolved: `sz, ts`
- ambiguous: [{"candidates": ["圣戒信条/TSLib.lua", "血战屠龙/TSLib.lua", "赤沙龙城/TSLib.lua"], "require": "TSLib"}]
- cycle: `False`
- API mapping: `mSleep` -> `sys.mSleep`, `getColor` -> `screen.getColor`, `findColorInRegionFuzzy` -> `image.findColor`, `findMultiColorInRegionFuzzy` -> `image.findMultiColorInRegionFuzzy`, `toast` -> `sys.toast`
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": false}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}

## `怒剑传奇/NJCQJH.lua`
- entry: `top_level_bootstrap`
- status: `unmigratable_static_only`
- requires: `TSLib, ts`
- dynamic requires: `DXMC.."HS", DXMC.."UI"`
- dependency status: `dynamic_and_static_unresolved`
- resolved: `none`
- unresolved: `ts`
- ambiguous: [{"candidates": ["圣戒信条/TSLib.lua", "血战屠龙/TSLib.lua", "赤沙龙城/TSLib.lua"], "require": "TSLib"}]
- cycle: `False`
- API mapping: none
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": false}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": true}
- gaps: `dynamic_module_path_unresolved`, `host_shell_or_file_mutation`

## `圣戒信条/SJXTJH.lua`
- entry: `top_level_bootstrap`
- status: `unmigratable_static_only`
- requires: `TSLib, ts`
- dynamic requires: `DXMC.."HS", DXMC.."UI"`
- dependency status: `dynamic_and_static_unresolved`
- resolved: `圣戒信条/TSLib.lua`
- unresolved: `ts`
- cycle: `False`
- API mapping: none
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": false}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}
- gaps: `dynamic_module_path_unresolved`

## `圣戒信条/TSLib.lua`
- entry: `library_or_unresolved`
- status: `dependency_only_or_no_allowlisted_api`
- requires: `none`
- dynamic requires: `none`
- dependency status: `resolved_or_external`
- resolved: `none`
- unresolved: `none`
- cycle: `False`
- API mapping: none
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": false}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}

## `圣戒信条加密/BBH.lua`
- entry: `library_or_unresolved`
- status: `dependency_only_or_no_allowlisted_api`
- requires: `none`
- dynamic requires: `none`
- dependency status: `resolved_or_external`
- resolved: `none`
- unresolved: `none`
- cycle: `False`
- API mapping: none
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": false}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}

## `圣戒信条加密/SJXTJH.lua`
- entry: `top_level_bootstrap`
- status: `partial_mapping_requires_rewrite`
- requires: `ts`
- dynamic requires: `(""..string.char(84)..string.char(83)..string.char(76)..string.char(105)..string.char(98)..""), DXMC.."HS", DXMC.."UI"`
- dependency status: `dynamic_and_static_unresolved`
- resolved: `none`
- unresolved: `ts`
- cycle: `False`
- API mapping: `mSleep` -> `sys.mSleep`, `closeApp` -> `app.appKill`, `setWifiEnable` -> `device.setWifiEnable`, `getNetIP` -> `net.getNetIP`
- stop: {"closeApp": true, "lua_exit": false, "unboundedLoop": true}
- cleanup: {"directFileIo": true, "remoteFtp": true, "shellMutation": true}
- gaps: `direct_file_io_needs_sandboxed_mapping`, `dynamic_module_path_unresolved`, `host_shell_or_file_mutation`, `remote_ftp_dependency`, `unbounded_loop_requires_stop_token`

## `系统工具/main.lua`
- entry: `top_level_entry`
- status: `partial_mapping_requires_rewrite`
- requires: `none`
- dynamic requires: `none`
- dependency status: `resolved_or_external`
- resolved: `none`
- unresolved: `none`
- cycle: `False`
- API mapping: `mSleep` -> `sys.mSleep`, `findMultiColorInRegionFuzzy` -> `image.findMultiColorInRegionFuzzy`, `touchDown` -> `touch.touchDown`, `touchUp` -> `touch.touchUp`, `toast` -> `sys.toast`
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": true}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}
- gaps: `unbounded_loop_requires_stop_token`

## `系统工具/ZYXiTongGongJu.lua`
- entry: `top_level_bootstrap`
- status: `partial_mapping_requires_rewrite`
- requires: `none`
- dynamic requires: `none`
- dependency status: `resolved_or_external`
- resolved: `none`
- unresolved: `none`
- cycle: `False`
- API mapping: `mSleep` -> `sys.mSleep`, `toast` -> `sys.toast`
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": true}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}
- gaps: `unbounded_loop_requires_stop_token`

## `新版血战加密/BBH.lua`
- entry: `library_or_unresolved`
- status: `dependency_only_or_no_allowlisted_api`
- requires: `none`
- dynamic requires: `none`
- dependency status: `resolved_or_external`
- resolved: `none`
- unresolved: `none`
- cycle: `False`
- API mapping: none
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": false}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}

## `新版血战加密/XBXZJH.lua`
- entry: `top_level_bootstrap`
- status: `partial_mapping_requires_rewrite`
- requires: `ts`
- dynamic requires: `(""..string.char(84)..string.char(83)..string.char(76)..string.char(105)..string.char(98)..""), DXMC.."HS", DXMC.."UI"`
- dependency status: `dynamic_and_static_unresolved`
- resolved: `none`
- unresolved: `ts`
- cycle: `False`
- API mapping: `mSleep` -> `sys.mSleep`, `closeApp` -> `app.appKill`, `setWifiEnable` -> `device.setWifiEnable`, `getNetIP` -> `net.getNetIP`
- stop: {"closeApp": true, "lua_exit": false, "unboundedLoop": true}
- cleanup: {"directFileIo": true, "remoteFtp": true, "shellMutation": true}
- gaps: `direct_file_io_needs_sandboxed_mapping`, `dynamic_module_path_unresolved`, `host_shell_or_file_mutation`, `remote_ftp_dependency`, `unbounded_loop_requires_stop_token`

## `血战加密/BBH.lua`
- entry: `library_or_unresolved`
- status: `dependency_only_or_no_allowlisted_api`
- requires: `none`
- dynamic requires: `none`
- dependency status: `resolved_or_external`
- resolved: `none`
- unresolved: `none`
- cycle: `False`
- API mapping: none
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": false}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}

## `血战加密/XZTLJH.lua`
- entry: `top_level_bootstrap`
- status: `partial_mapping_requires_rewrite`
- requires: `ts`
- dynamic requires: `(""..string.char(84)..string.char(83)..string.char(76)..string.char(105)..string.char(98)..""), DXMC.."HS", DXMC.."UI"`
- dependency status: `dynamic_and_static_unresolved`
- resolved: `none`
- unresolved: `ts`
- cycle: `False`
- API mapping: `mSleep` -> `sys.mSleep`, `closeApp` -> `app.appKill`, `setWifiEnable` -> `device.setWifiEnable`, `getNetIP` -> `net.getNetIP`
- stop: {"closeApp": true, "lua_exit": false, "unboundedLoop": true}
- cleanup: {"directFileIo": true, "remoteFtp": true, "shellMutation": true}
- gaps: `direct_file_io_needs_sandboxed_mapping`, `dynamic_module_path_unresolved`, `host_shell_or_file_mutation`, `remote_ftp_dependency`, `unbounded_loop_requires_stop_token`

## `血战屠龙/BBH.lua`
- entry: `library_or_unresolved`
- status: `dependency_only_or_no_allowlisted_api`
- requires: `none`
- dynamic requires: `none`
- dependency status: `resolved_or_external`
- resolved: `none`
- unresolved: `none`
- cycle: `False`
- API mapping: none
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": false}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}

## `血战屠龙/ceshi.lua`
- entry: `top_level_bootstrap`
- status: `partial_mapping_requires_rewrite`
- requires: `TSLib, socket`
- dynamic requires: `none`
- dependency status: `static_unresolved`
- resolved: `血战屠龙/TSLib.lua`
- unresolved: `socket`
- cycle: `False`
- API mapping: `mSleep` -> `sys.mSleep`, `toast` -> `sys.toast`, `setWifiEnable` -> `device.setWifiEnable`, `getNetIP` -> `net.getNetIP`
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": true}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}
- gaps: `external_socket_dependency`, `unbounded_loop_requires_stop_token`

## `血战屠龙/TSLib.lua`
- entry: `library_or_unresolved`
- status: `dependency_only_or_no_allowlisted_api`
- requires: `none`
- dynamic requires: `none`
- dependency status: `resolved_or_external`
- resolved: `none`
- unresolved: `none`
- cycle: `False`
- API mapping: none
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": false}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}

## `血战屠龙/XZJH.lua`
- entry: `top_level_bootstrap`
- status: `partial_mapping_requires_rewrite`
- requires: `TSLib, XZHS, XZQS, XZUI, ts`
- dynamic requires: `none`
- dependency status: `static_unresolved`
- resolved: `血战屠龙/TSLib.lua`
- unresolved: `XZHS, XZQS, XZUI, ts`
- cycle: `False`
- API mapping: `mSleep` -> `sys.mSleep`, `closeApp` -> `app.appKill`, `toast` -> `sys.toast`, `lua_exit` -> `script.lua_exit`, `setWifiEnable` -> `device.setWifiEnable`, `getNetIP` -> `net.getNetIP`
- stop: {"closeApp": true, "lua_exit": true, "unboundedLoop": true}
- cleanup: {"directFileIo": true, "remoteFtp": true, "shellMutation": true}
- gaps: `direct_file_io_needs_sandboxed_mapping`, `host_shell_or_file_mutation`, `remote_ftp_dependency`, `unbounded_loop_requires_stop_token`

## `血战优化/XZTLJH.lua`
- entry: `top_level_bootstrap`
- status: `partial_mapping_requires_rewrite`
- requires: `TSLib, ts`
- dynamic requires: `DXMC.."HS", DXMC.."UI"`
- dependency status: `dynamic_and_static_unresolved`
- resolved: `none`
- unresolved: `ts`
- ambiguous: [{"candidates": ["圣戒信条/TSLib.lua", "血战屠龙/TSLib.lua", "赤沙龙城/TSLib.lua"], "require": "TSLib"}]
- cycle: `False`
- API mapping: `mSleep` -> `sys.mSleep`
- stop: {"closeApp": false, "lua_exit": false, "unboundedLoop": false}
- cleanup: {"directFileIo": false, "remoteFtp": false, "shellMutation": false}
- gaps: `dynamic_module_path_unresolved`
