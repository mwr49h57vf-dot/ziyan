#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
res/*.py 启动器：注入 ziyan_res（lua_call / lua_eval），再执行用户脚本。
由 ZiYanScriptRunner 调用：python3 py_boot.py <user.py>
"""
from __future__ import print_function

import os
import runpy
import sys

RES_DIR = "/private/var/mobile/Media/ZiYan/res"
ZIYAN_BIN = "/usr/lib/ziyan/bin"
ZIYAN_CV = "/usr/lib/ziyan/bin/ziyan_cv"


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: py_boot.py <script.py>\n")
        return 2
    user = os.path.abspath(sys.argv[1])
    for p in (ZIYAN_CV, ZIYAN_BIN, RES_DIR, os.path.dirname(user)):
        if p and p not in sys.path:
            sys.path.insert(0, p)
    try:
        import ziyan_res

        ziyan_res.inject_builtins()
    except Exception as e:
        sys.stderr.write("[py_boot] ziyan_res inject failed: %s\n" % e)
    # 用户脚本以 __main__ 执行
    sys.argv = [user] + sys.argv[2:]
    runpy.run_path(user, run_name="__main__")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
