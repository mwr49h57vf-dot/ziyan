"""Compile a candidate with the configured Lua interpreter, without executing it."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

CHECKER = "local f,e=loadfile(arg[0], 't'); if not f then io.stderr:write(tostring(e)) end; os.exit(f and 0 or 1)"

def validate_script_syntax(source, executable=None):
    data=source.encode('utf8')
    if not data or len(data)>1024*1024:
        return False,'lua_source_size_invalid'
    executable=executable or os.environ.get('ZIYAN_SCRIPTGEN_LUA') or shutil.which('lua5.3') or shutil.which('lua')
    if not executable:
        return False,'lua_syntax_tool_unavailable'
    try:
        with tempfile.TemporaryDirectory(prefix='ziyan-syntax-') as temporary:
            path=Path(temporary)/'candidate.lua'
            path.write_bytes(data)
            result=subprocess.run([executable,'-E','-e',CHECKER,'--',str(path)],
                                  stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=5)
            return (True,None) if result.returncode==0 else (False,'lua_syntax_check_failed')
    except subprocess.TimeoutExpired:
        return False,'lua_syntax_check_timeout'
    except OSError:
        return False,'lua_syntax_tool_unavailable'
