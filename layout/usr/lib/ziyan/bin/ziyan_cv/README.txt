ziyan_cv 旧 Python CV / run CLI 已拆除（勿再调用本目录 run）。

当前实现：
  找色   lua/ziyan_engine/cv.lua → SpringBoard ZiYanScreenBridge
  截屏   dumpScreen → /usr/lib/ziyan/var/.ziyan_cv_shot.png（兼 Media/ZiYan/ts_shot.png）
  OCR    /usr/lib/ziyan/bin/ziyan_ocr（Vision）
  内存   ZiYanMemHook + /usr/lib/ziyan/bin/ziyan_mem
  点触   lua/ziyan_engine/touch.lua → ZiYanAppTouch（游戏内）/ ScreenBridge HID 兜底
  文档   /usr/lib/ziyan/modules/ziyan_cv函数说明.html

res/ Lua↔Python 互通（子进程 + JSON）：
  py_boot.py     启动 res/*.py，注入 lua_call / lua_eval
  ziyan_res.py   Python 侧桥 + 供 Lua pyCall 调用
  Lua API        pyCall(module, func, args?) / pyEval(path)
  Lua 桥         /usr/lib/ziyan/lib/lua/ziyan_res_bridge.lua
  示例           Media/ZiYan/res/demo_*.{lua,py}
