import sys, subprocess, importlib.util, unittest, os
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/ziyan_scriptgen_sidecar'))
from dependency_contract import dependency_contract
import sidecar_server
class NativeDependencyContract(unittest.TestCase):
 def native(self,source):
  p=subprocess.run([str(ROOT/('tmp_shots/repair-20260912/script_dependency_cli'+('.exe' if os.name=='nt' else '')))],input=source.encode(),capture_output=True,check=True)
  return tuple(map(int,p.stdout.split()))
 def test_shared_samples(self):
  samples=[
   ('local note="TSLib"',0), ('-- require("TSLib")\nlocal a=1',0),
   ('--[=[\nrequire("ts")\n]=]\nlocal a=1',0), ('local s=[==[TSLib require("ts")]==]',0),
   ('require "TSLib"',1), ('require --comment\n("ts")',1), ('require([=[sz]=])',1),
   (r'require("\84SLib")',1), (r'require("\x54SLib")',1), (r'require("\u{54}SLib")',1),
   ('local a=TSLib.init()',1), ('require("ziyan_engine")',0),
   ('_G["require"]("ts")',3), ('load("return require(\"ts\")")()',3), ('require("'+('a'*260)+'/ts")',3),
   ('require("x" and "ts")',3), ('require("x" or "ts")',3), ('require("x", "ts")',3), ('require("x" .. "ts")',3),
   ('require(packageName)',3), ('require("T" .. "SLib")',3), ('pcall(require,"ts")',3),
   ('require("TSLib)',2), ('--[=[unfinished',2), ('local x="unterminated',2),
   ('local note="phase_login phase_role_select phase_enter_game phase_auto_battle runApp"',0),
  ]
  for source,expected in samples:
   with self.subTest(source=source):
    self.assertEqual(self.native(source)[0],expected)
    self.assertEqual(dependency_contract(source)[0],expected)
 def test_real_generator_passes_native_and_lua_load(self):
  source=sidecar_server.emit_full_lua({'bid':'fixture.app'}, {})
  for candidate in [source, source+'\nlocal note="TSLib"', source+'\n--[=[require("ts")]=]']:
   self.assertEqual(self.native(candidate),(0,31))
   self.assertTrue(sidecar_server.score_mmbert(candidate)['ok'])
  p=ROOT/'tmp_shots/repair-20260912/generated-script.lua';p.write_text(source,encoding='utf8')
  subprocess.run([os.environ.get('ZIYAN_REPAIR_LUA',str(ROOT/'tmp_shots/repair-20260912/toolchain/lua-5.3.5/src/lua-fixed.exe')),'-e',"assert(loadfile('tmp_shots/repair-20260912/generated-script.lua'))"],cwd=ROOT,check=True)
 def test_markers_only_in_comments_or_strings_do_not_pass(self):
  source='-- phase_login phase_role_select phase_enter_game phase_auto_battle runApp\nlocal note="phase_login"'
  self.assertEqual(self.native(source),(0,0))
  self.assertFalse(sidecar_server.score_mmbert(source)['ok'])
  source='local phase_login, phase_role_select, phase_enter_game, phase_auto_battle\nrunApp("fixture.app")'
  self.assertEqual(self.native(source),(0,16))
  self.assertFalse(sidecar_server.score_mmbert(source)['ok'])
if __name__=='__main__':unittest.main()
