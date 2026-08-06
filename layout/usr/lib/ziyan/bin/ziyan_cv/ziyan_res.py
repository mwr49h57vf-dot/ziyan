#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ZiYan res/ Lua↔Python 互通（子进程 + JSON）。"""
from __future__ import print_function

import importlib.util
import json
import os
import subprocess
import sys
import traceback

RES_DIR = "/private/var/mobile/Media/ZiYan/res"
ZIYAN_BIN = "/usr/lib/ziyan/bin"
ZIYAN_CV = "/usr/lib/ziyan/bin/ziyan_cv"
LUA = "/usr/lib/ziyan/bin/lua5.3"
LUA_BRIDGE = "/usr/lib/ziyan/lib/lua/ziyan_res_bridge.lua"
VAR = "/usr/lib/ziyan/var"
STOP = os.path.join(VAR, ".ziyan_stop")


def _ensure_paths():
    for p in (ZIYAN_CV, ZIYAN_BIN, RES_DIR):
        if p and p not in sys.path:
            sys.path.insert(0, p)


def _check_stop():
    if os.path.exists(STOP):
        raise RuntimeError("ziyan_stop")


def _write_json(path, obj):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        try:
            os.makedirs(d)
        except Exception:
            pass
    with open(path, "w") as f:
        json.dump(obj, f, ensure_ascii=False)


def _read_json(path):
    with open(path, "r") as f:
        return json.load(f)


def _resolve_py(module_or_path):
    mod = str(module_or_path or "")
    if not mod:
        raise ValueError("empty module")
    if mod.endswith(".py") or mod.startswith("/"):
        path = mod if mod.startswith("/") else os.path.join(RES_DIR, mod)
        if not path.endswith(".py"):
            path = path + ".py"
        return path
    return os.path.join(RES_DIR, mod + ".py")


def _load_py_module(module_or_path):
    path = _resolve_py(module_or_path)
    if not os.path.isfile(path):
        raise FileNotFoundError(path)
    name = os.path.splitext(os.path.basename(path))[0]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load " + path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def call_py(module_or_path, func, args=None):
    """供 Lua pyCall / CLI 使用。"""
    _check_stop()
    _ensure_paths()
    m = _load_py_module(module_or_path)
    fn = getattr(m, str(func), None)
    if not callable(fn):
        raise AttributeError("function not found: %s" % func)
    args = args if isinstance(args, (list, tuple)) else []
    return fn(*args)


def eval_py(path):
    """运行整个 py；若定义 main() 则调用。"""
    _check_stop()
    _ensure_paths()
    path = str(path or "")
    if not path.startswith("/"):
        path = os.path.join(RES_DIR, path)
    if not os.path.isfile(path):
        raise FileNotFoundError(path)
    g = {"__name__": "__main__", "__file__": path}
    with open(path, "r") as f:
        code = f.read()
    exec(compile(code, path, "exec"), g, g)
    if callable(g.get("main")):
        return g["main"]()
    return g.get("result")


def lua_call(module_or_path, func, args=None, opts=None):
    """Python → Lua：调用 res 或路径下的函数。返回 dict: ok/result/error。"""
    _check_stop()
    opts = opts or {}
    timeout = float(opts.get("timeout") or 30)
    req = os.path.join(VAR, ".ziyan_res_lua_req.json")
    rep = os.path.join(VAR, ".ziyan_res_lua_rep.json")
    try:
        if os.path.exists(rep):
            os.remove(rep)
    except Exception:
        pass
    payload = {
        "op": "call_lua",
        "module": module_or_path,
        "func": func,
        "args": list(args or []),
    }
    _write_json(req, payload)
    env = os.environ.copy()
    env["LUA_PATH"] = ";".join(
        [
            RES_DIR + "/?.lua",
            RES_DIR + "/?/init.lua",
            "/usr/lib/ziyan/lib/lua/?.lua",
            "/usr/lib/ziyan/lib/lua/?/init.lua",
            "/usr/lib/ziyan/lib/lua/ziyan_engine/?.lua",
            env.get("LUA_PATH", ""),
        ]
    )
    cmd = [LUA, LUA_BRIDGE, "--req", req, "--rep", rep]
    try:
        subprocess.run(
            cmd,
            env=env,
            timeout=timeout,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except Exception as e:
        return {"ok": False, "error": str(e)}
    if not os.path.isfile(rep):
        return {"ok": False, "error": "no lua reply"}
    try:
        return _read_json(rep)
    except Exception as e:
        return {"ok": False, "error": "bad lua reply: %s" % e}


def lua_eval(path, opts=None):
    """运行整个 lua（可含 main）。"""
    _check_stop()
    opts = opts or {}
    timeout = float(opts.get("timeout") or 30)
    req = os.path.join(VAR, ".ziyan_res_lua_req.json")
    rep = os.path.join(VAR, ".ziyan_res_lua_rep.json")
    try:
        if os.path.exists(rep):
            os.remove(rep)
    except Exception:
        pass
    _write_json(req, {"op": "eval_lua", "path": path})
    env = os.environ.copy()
    env["LUA_PATH"] = ";".join(
        [
            RES_DIR + "/?.lua",
            RES_DIR + "/?/init.lua",
            "/usr/lib/ziyan/lib/lua/?.lua",
            "/usr/lib/ziyan/lib/lua/?/init.lua",
            "/usr/lib/ziyan/lib/lua/ziyan_engine/?.lua",
            env.get("LUA_PATH", ""),
        ]
    )
    try:
        subprocess.run(
            [LUA, LUA_BRIDGE, "--req", req, "--rep", rep],
            env=env,
            timeout=timeout,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except Exception as e:
        return {"ok": False, "error": str(e)}
    if not os.path.isfile(rep):
        return {"ok": False, "error": "no lua reply"}
    try:
        return _read_json(rep)
    except Exception as e:
        return {"ok": False, "error": "bad lua reply: %s" % e}


def inject_builtins():
    """注入到 builtins，供 res/*.py 直接调用。"""
    import builtins

    builtins.lua_call = lua_call
    builtins.lua_eval = lua_eval
    builtins.call_py = call_py


def handle_req(req_path, rep_path):
    try:
        payload = _read_json(req_path)
        op = payload.get("op")
        if op == "call_py":
            result = call_py(payload.get("module"), payload.get("func"), payload.get("args"))
            _write_json(rep_path, {"ok": True, "result": result})
        elif op == "eval_py":
            result = eval_py(payload.get("path"))
            _write_json(rep_path, {"ok": True, "result": result})
        else:
            _write_json(rep_path, {"ok": False, "error": "unknown op: %s" % op})
    except Exception as e:
        _write_json(
            rep_path,
            {"ok": False, "error": "%s\n%s" % (e, traceback.format_exc())},
        )


def main(argv=None):
    argv = list(argv or sys.argv[1:])
    _ensure_paths()
    req = rep = None
    i = 0
    while i < len(argv):
        if argv[i] == "--req" and i + 1 < len(argv):
            req = argv[i + 1]
            i += 2
        elif argv[i] == "--rep" and i + 1 < len(argv):
            rep = argv[i + 1]
            i += 2
        else:
            i += 1
    if req and rep:
        handle_req(req, rep)
        return 0
    print("usage: ziyan_res.py --req <json> --rep <json>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
