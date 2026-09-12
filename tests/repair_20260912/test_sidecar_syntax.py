import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/ziyan_scriptgen_sidecar'))
import sidecar_server as sidecar
from syntax_contract import validate_script_syntax
LUA=os.environ.get('ZIYAN_TEST_LUA',str(ROOT/'tmp_shots/repair-20260912/toolchain/lua-5.3.5/src/lua-fixed.exe'))
class SidecarSyntax(unittest.TestCase):
 def test_compiler_failure_and_no_execution(self):
  with tempfile.TemporaryDirectory(prefix='sidecar-syntax-',dir=ROOT/'tests') as directory:
   sentinel=Path(directory)/'ran'
   source='local f=assert(io.open('+json.dumps(sentinel.as_posix())+',"w")); f:write("ran"); f:close()'
   self.assertEqual(validate_script_syntax(source,LUA),(True,None))
   self.assertFalse(sentinel.exists())
   self.assertFalse(validate_script_syntax('if then',LUA)[0])
   self.assertFalse(validate_script_syntax('return true',str(Path(directory)/'missing-lua'))[0])
 def test_http_source_flags_and_fallback_conditions(self):
  with tempfile.TemporaryDirectory(prefix='sidecar-http-',dir=ROOT/'tests') as directory:
   with patch.object(sidecar,'AUDIT',Path(directory)), patch.object(sidecar,'load_family',return_value={}), patch.object(sidecar,'weight_ready',return_value=(False,0)), patch.dict(os.environ,{'ZIYAN_SCRIPTGEN_LUA':LUA}):
    server=ThreadingHTTPServer(('127.0.0.1',0),sidecar.Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    def request():
     req=urllib.request.Request('http://127.0.0.1:%d/v1/scriptgen/run'%server.server_port,data=b'{"bid":"fixture.app"}',headers={'Content-Type':'application/json'})
     with urllib.request.urlopen(req,timeout=10) as response: return json.load(response)
    try:
     with urllib.request.urlopen('http://127.0.0.1:%d/health'%server.server_port,timeout=5) as health: self.assertTrue(json.load(health)['ok'])
     valid=sidecar.emit_full_lua({'bid':'fixture.app'}, {})
     response=request()
     self.assertTrue(response['ok'] and response['from_sidecar'] and response['syntax_checked'])
     for extra in ['\nif then', '\n_G["require"]("ts")', '\nload("return true")()']:
      with patch.object(sidecar,'emit_full_lua',return_value=valid+extra): response=request()
      self.assertFalse(response['ok'] or response['from_sidecar'])
      self.assertTrue(response['error'])
    finally:
     server.shutdown();server.server_close();thread.join(timeout=2)
if __name__=='__main__':unittest.main()
