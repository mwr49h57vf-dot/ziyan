# P0 落地清单（启动 + Orient）

## 已落实（引擎侧）

1. **启动不堵 completion**  
   `ZiYanScriptRunner runFileAtPath` 对 `.lua` 走 `runLuaDetachedAtPath`（lua5.3 nohup），启动成功即返回，不等脚本结束。  
   `ceshiRootViewController` 在 `success` 后立即 `ZiYanMinimizeApp()`。

2. **find / tap 同向**  
   Lua `touch.lua` 注释约定：逻辑坐标交给 Oc，**禁止**脚本侧先 `to_phys`。  
   `ZiYanOrientMap.h`：`ZiYanMapLogicToBuffer` / `ZiYanMapLogicToWindowNorm` 供 ScreenBridge 与 AppTouch 共用。  
   `init.lua` 统一设置 `_G.ZIYAN_VAR` / `ZIYAN_ZYCV`，避免 rootless/rootful 读写分裂。

3. **Orient 自检脚本（无业务色点）**  
   装机路径：`/private/var/mobile/Media/ZiYan/_orient_selftest.lua`  
   仓库：`layout/private/var/mobile/Media/ZiYan/_orient_selftest.lua`  
   报告：`Media/ZiYan/ZYCV/_orient_selftest.txt`

## 真机怎么验

```text
1. make package / make package-rootless（按设备）
2. 安装到 USB 与 LAN
3. App 勾选 _orient_selftest.lua → 点 Play（或运行）
4. 应最小化；数秒后结束（非死循环）
5. 拉 ZYCV/_orient_selftest.txt，fails=0
6. 再用业务脚本验 find→tap（勿改色点凑数）
```

## 仍须人工盯

- USB 点运行/Play 是否仍会 SB 重启（抓 crash 再定）
- 文案「运行」与 Play 是否完全同一路径
- 业务色点 find/OCR 在正确前台下的命中率
