"""Real Lua CLI checks; native Foundation integration also runs on macOS."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "objc/app/ZiYanScriptSyntax.h"
LUA = os.environ.get("ZIYAN_TEST_LUA") or shutil.which("lua5.3") or shutil.which("lua")


class ScriptSyntax(unittest.TestCase):
    def checker(self):
        source = HEADER.read_text(encoding="utf-8")
        match = re.search(r'^#define ZIYAN_LUA_SYNTAX_CHECKER (".*")$', source, re.M)
        self.assertIsNotNone(match, "Production checker must be shared with CLI tests")
        return json.loads(match[1])

    def run_lua(self, source, extra_env=None):
        if not LUA:
            self.skipTest("Set ZIYAN_TEST_LUA to an actual Lua 5.3 executable")
        with tempfile.TemporaryDirectory(prefix="syntax-", dir=ROOT / "tests") as td:
            path = Path(td) / "candidate.lua"
            path.write_text(source, encoding="utf-8")
            result = subprocess.run([LUA, "-E", "-e", self.checker(), "--", str(path)],
                                    capture_output=True, text=True, timeout=5,
                                    env=dict(os.environ, **(extra_env or {})))
            return result

    def test_normal_script_compiles(self):
        result = self.run_lua("function main() return true end\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bad_syntax_fails(self):
        result = self.run_lua("function main( return true end\n")
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_top_level_script_is_never_executed(self):
        with tempfile.TemporaryDirectory(prefix="syntax-sentinel-", dir=ROOT / "tests") as td:
            sentinel = Path(td) / "candidate-ran"
            source = ('local f=assert(io.open(' + json.dumps(sentinel.as_posix()) +
                      ', "w")); f:write("ran"); f:close(); error("candidate executed")\n')
            result = self.run_lua(source)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(sentinel.exists())

    def test_lua_init_is_never_executed(self):
        with tempfile.TemporaryDirectory(prefix="syntax-init-", dir=ROOT / "tests") as td:
            sentinel = Path(td) / "init-ran"
            init = Path(td) / "init.lua"
            init.write_text('local f=assert(io.open(' + json.dumps(sentinel.as_posix()) +
                            ', "w")); f:write("ran"); f:close(); error("init executed")\n')
            result = self.run_lua("return true\n", {"LUA_INIT": "@" + str(init),
                                                      "LUA_INIT_5_3": "@" + str(init)})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(sentinel.exists())

    @unittest.skipUnless(sys.platform == "darwin", "Native Foundation build requires macOS SDK")
    def test_native_limits_cleanup_and_result(self):
        if not LUA:
            self.skipTest("Set ZIYAN_TEST_LUA to an actual Lua 5.3 executable")
        with tempfile.TemporaryDirectory(prefix="syntax-native-", dir=ROOT / "tests") as td:
            root = Path(td)
            sleeper = root / "sleeper.c"
            sleeper.write_text("#include <unistd.h>\n#include <stdio.h>\n#include <stdlib.h>\n"
                               "int main(void) {FILE *f=fopen(getenv(\"ZIYAN_SYNTAX_CHILD_PID\"),\"w\");"
                               "if(!f)return 2;fprintf(f,\"%ld\",(long)getpid());fclose(f);sleep(20);return 0;}\n")
            sleep_bin = root / "sleeper"
            subprocess.run(["clang", str(sleeper), "-o", str(sleep_bin)], check=True)
            source = root / "test.m"
            source.write_text(r'''
#import "ZiYanScriptSyntax.h"
int main(int argc, char **argv) {
  @autoreleasepool {
    NSString *lua = [NSString stringWithUTF8String:argv[1]];
    NSString *sleeper = [NSString stringWithUTF8String:argv[2]];
    NSString *error = nil;
    NSArray *before = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil];
    if (!ZiYanValidateLuaSyntax(@"function main() return true end", lua, &error) || error) return 1;
    if (ZiYanValidateLuaSyntax(@"function main( end", lua, &error) || ![error hasPrefix:@"LUA_SYNTAX_PARSE_FAILED"]) return 2;
    if (ZiYanValidateLuaSyntax(@"return true", @"/missing/ziyan-lua", &error) || ![error hasPrefix:@"LUA_SYNTAX_TOOL_MISSING"]) return 3;
    NSString *huge = [@" " stringByPaddingToLength:1024 * 1024 + 1 withString:@" " startingAtIndex:0];
    if (ZiYanValidateLuaSyntax(huge, lua, &error) || ![error hasPrefix:@"LUA_SYNTAX_INPUT_TOO_LARGE"]) return 4;
    NSString *unicode = [@"中" stringByPaddingToLength:400000 withString:@"中" startingAtIndex:0];
    if (ZiYanValidateLuaSyntax(unicode, lua, &error) || ![error hasPrefix:@"LUA_SYNTAX_INPUT_TOO_LARGE"]) return 8;
    if (ZiYanValidateLuaSyntax(@"return true", sleeper, &error) || ![error hasPrefix:@"LUA_SYNTAX_TIMEOUT"]) return 5;
    NSString *pidfile = [[[NSProcessInfo processInfo] environment] objectForKey:@"ZIYAN_SYNTAX_CHILD_PID"];
    pid_t child = (pid_t)[[NSString stringWithContentsOfFile:pidfile encoding:NSUTF8StringEncoding error:nil] intValue];
    if (child <= 0 || kill(child, 0) == 0 || errno != ESRCH) return 7;
    NSArray *after = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil];
    NSMutableSet *newFiles = [NSMutableSet setWithArray:after];
    [newFiles minusSet:[NSSet setWithArray:before]];
    for (NSString *name in newFiles) if ([name hasPrefix:@"ziyan-lua-syntax."]) return 6;
  }
  return 0;
}
''', encoding="utf-8")
            executable = root / "native-test"
            subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation", "-I",
                            str(ROOT / "objc/app"), str(source), "-o", str(executable)], check=True)
            result = subprocess.run([str(executable), LUA, str(sleep_bin)], timeout=8,
                                    env=dict(os.environ, ZIYAN_SYNTAX_CHILD_PID=str(root / "child.pid")))
            self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
