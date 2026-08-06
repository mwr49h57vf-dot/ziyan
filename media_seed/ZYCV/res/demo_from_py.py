# Python → Lua：lua_call("demo_lua_lib","mul",[4,5])
OUT = "/usr/lib/ziyan/var/.ziyan_res_interop_test.txt"


def main():
    # py_boot 已注入；手动跑时再 import
    try:
        lc = lua_call  # noqa: F821 builtins
    except NameError:
        import ziyan_res

        lc = ziyan_res.lua_call
    ret = lc("demo_lua_lib", "mul", [4, 5])
    ok = bool(ret.get("ok")) and ret.get("result") == 20
    with open(OUT, "w") as f:
        if ok:
            f.write("PASS py->lua mul=20\n")
        else:
            f.write("FAIL py->lua %s\n" % (ret,))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
