# ZiYan 函数说明（API）
> 由 `api_spec/catalog.json` + `modules/*.json` 生成；生成时间 2026-07-19 18:59。
> 总数 **99** · done **53** · partial **27** · planned **19**
> catalog 声明：total=99 / {'done': 53, 'planned': 19, 'partial': 27}

坐标系默认：`init(1)` 逻辑横屏（常见 1136×640）；触控/找色经 `.ziyan_*` IPC。

## 一致性核对（未改语义，仅标注）

**api_spec 标 done，但 lua/ziyan_engine 文本未检出符号：**
- `clipText`

**api_spec 标 planned，但 lua 中已出现名字（可能 stub/别名）：**
- `keyDown`
- `keyUp`
- `findMultiColorInRegionFuzzyEx`

## sys — 系统 / 提示 / 延时

- backend: `lua/ziyan_engine/{control,toast,device}.lua + SpringBoard toast bridge`
- count: 16（done 8 / partial 5 / planned 3）

| 函数名 | 模块 | 参数 | 返回值 | 含义 | 实现位置 | 状态 | 备注 |
|---|---|---|---|---|---|---|---|
| mSleep | sys | ms:number | void | 延时毫秒；内含暂停/停止检查点 | lua/ziyan_engine/control.lua | done | 延时毫秒；内含暂停/停止检查点 |
| toast | sys | any, ms?:number | void | 非阻塞吐司 | lua/ziyan_engine/toast.lua | done | 非阻塞吐司 |
| notifyMessage | sys | any, ms?:number | void | 消息提示（对齐 dialog 语义） | lua/ziyan_engine/toast.lua | done | 消息提示（对齐 dialog 语义） |
| logDebug | sys | any | void | 调试日志 | lua/ziyan_run.lua | done | 调试日志 |
| scriptStop | sys |  | void | 安静退出脚本 | lua/ziyan_run.lua | done | 安静退出脚本 |
| notifyVibrate | sys | ms?:number | bool | 震动 | (see module backend) | planned | 震动 |
| notifyVoice | sys | path:string | bool | 播放提示音 | (see module backend) | planned | 播放提示音 |
| inputText | sys | text:string | bool | 输入文字 | lua/ziyan_engine/ts_alias.lua | partial | 输入文字 |
| openURL | sys | url:string | bool | 打开 URL / Bundle | (see module backend) | partial | 打开 URL / Bundle |
| getDeviceID | sys |  | string | 设备标识 | (see module backend) | planned | 设备标识 |
| copyText | sys | text:string | bool | 写剪贴板 | lua/ziyan_engine/ts_alias.lua | done | 写剪贴板；别名: CopyClipboard, writePasteboard |
| clipText | sys |  | string | 读剪贴板 | (see module backend) | done | 读剪贴板；别名: PasteClipboard, readPasteboard |
| deviceIsLock | sys |  | number | 锁屏状态 0/1 | lua/ziyan_engine/device.lua | partial | 锁屏状态 0/1 |
| deviceUnlock | sys | pass?:string | bool | 解锁 | lua/ziyan_engine/ts_alias.lua | partial | 解锁；别名: unlockDevice |
| userPath | sys |  | string | 脚本工程目录 Media/ZiYan | lua/ziyan_engine/device.lua | done | 脚本工程目录 Media/ZiYan |
| getVersion | sys |  | string | 子砚引擎版本 | (see module backend) | partial | 子砚引擎版本 |

## touch — 触控 / 按键

- backend: `lua/ziyan_engine/touch.lua + AppTouch / ScreenBridge HID`
- count: 8（done 5 / partial 1 / planned 2）

| 函数名 | 模块 | 参数 | 返回值 | 含义 | 实现位置 | 状态 | 备注 |
|---|---|---|---|---|---|---|---|
| touchDown | touch | finger?:number, x:number, y:number | bool | 按下；支持 touchDown(x,y) | lua/ziyan_engine/touch.lua | done | 按下；支持 touchDown(x,y) |
| touchMove | touch | finger?:number, x:number, y:number | bool | 移动 | lua/ziyan_engine/touch.lua | done | 移动 |
| touchUp | touch | finger?:number, x?:number, y?:number | bool | 抬起 | lua/ziyan_engine/touch.lua | done | 抬起 |
| tap | touch | finger?:number, x:number, y:number, holdMs?:number | bool | tap(x,y[,holdMs]) 默认随机手指1..9；或 tap(finger,x,y[,holdMs])；真人按下→微移→抬起 | lua/ziyan_engine/touch.lua | done | tap(x,y[,holdMs]) 默认随机手指1..9；或 tap(finger,x,y[,holdMs])；真人按下→微移→抬起；别名: pyTap |
| swipe | touch | x1, y1, x2, y2, ms?:number | bool | 滑动 | lua/ziyan_engine/touch.lua | done | 滑动；别名: pySwipe, moveTo |
| keyDown | touch | code:number\|string | bool | 按键按下 | lua/ziyan_engine/ts_alias.lua | planned | 按键按下 |
| keyUp | touch | code:number\|string | bool | 按键抬起 | lua/ziyan_engine/ts_alias.lua | planned | 按键抬起 |
| pressHomeKey | touch | times?:number | bool | Home | lua/ziyan_engine/ts_alias.lua | partial | Home |

## screen — 屏幕 / 取色 / 找色 / 截屏 / 方向

- backend: `lua/ziyan_engine/{cv,color,orient,screen}.lua + ZiYanScreenBridge`
- count: 15（done 5 / partial 9 / planned 1）

| 函数名 | 模块 | 参数 | 返回值 | 含义 | 实现位置 | 状态 | 备注 |
|---|---|---|---|---|---|---|---|
| init | screen | orient:number | bool | 0 Home下 1右 2左；逻辑坐标基准 | lua/ziyan_engine/orient.lua | done | 0 Home下 1右 2左；逻辑坐标基准 |
| getColor | screen | x, y | number | 逻辑坐标取色 0xRRGGBB | lua/ziyan_engine/cv.lua | done | 逻辑坐标取色 0xRRGGBB |
| getColorRGB | screen | x, y | r,g,b | 拆分 RGB | lua/ziyan_engine/color.lua | partial | 拆分 RGB |
| findColor | screen | color | x,y | 全屏单色 | lua/ziyan_engine/color.lua | partial | 全屏单色 |
| findColorFuzzy | screen | color, fuzzy | x,y | 全屏+精度 | lua/ziyan_engine/color.lua | partial | 全屏+精度 |
| findColorInRegion | screen | color, x1, y1, x2, y2 | x,y | 区域单色 | lua/ziyan_engine/color.lua | partial | 区域单色 |
| findColorInRegionFuzzy | screen | color, fuzzy, x1, y1, x2, y2 | x,y | 区域+精度 | lua/ziyan_engine/color.lua | partial | 区域+精度 |
| findMultiColorInRegionFuzzy | screen | main, offsetStr, fuzzy, x1, y1, x2, y2 | x,y | TS/TE 多点找色主路径 | lua/ziyan_engine/cv.lua | done | TS/TE 多点找色主路径；别名: findMultiColor, pyFindMultiColor, pyFindColor |
| findMultiColorInRegionFuzzyEx | screen | main, offsetStr, fuzzy, x1, y1, x2, y2 | table | 返回全部命中 | lua/ziyan_engine/color.lua | planned | 返回全部命中 |
| keepScreen | screen | on:boolean | void | 缓存开关（占位/桥接） | lua/ziyan_engine/screen.lua | partial | 缓存开关（占位/桥接） |
| rotateScreen | screen | deg:number | bool | 旋转提示（逻辑向由 init 管） | lua/ziyan_engine/orient.lua | partial | 旋转提示（逻辑向由 init 管） |
| getScreenResolution | screen |  | w,h | 逻辑分辨率 | lua/ziyan_engine/orient.lua | partial | 逻辑分辨率；别名: getScreenSize |
| dumpScreen | screen | path?:string | string\|nil | 逻辑方向 PNG | lua/ziyan_engine/cv.lua | done | 逻辑方向 PNG |
| snapshot | screen | path?:string | bool | 截屏别名 | lua/ziyan_engine/cv.lua | done | 截屏别名；别名: snapshotScreen, pySnapshot |
| snapshotRegion | screen | path, x1, y1, x2, y2, scale? | bool | 区域截屏 | lua/ziyan_engine/screen.lua | partial | 区域截屏；别名: ZiYanCV.capture_region |

## image — 找图 / 图像处理

- backend: `lua/ziyan_engine/{cv,py_cv}.lua + ScreenBridge findImage`
- count: 9（done 1 / partial 3 / planned 5）

| 函数名 | 模块 | 参数 | 返回值 | 含义 | 实现位置 | 状态 | 备注 |
|---|---|---|---|---|---|---|---|
| findImage | image | path, trans? | x,y | 全屏找图 | lua/ziyan_engine/color.lua | partial | 全屏找图；别名: pyFindImage |
| findImageFuzzy | image | path, fuzzy, trans? | x,y | 全屏+精度 | lua/ziyan_engine/color.lua | partial | 全屏+精度 |
| findImageInRegion | image | path, x1, y1, x2, y2, trans? | x,y | 区域找图 | lua/ziyan_engine/color.lua | partial | 区域找图 |
| findImageInRegionFuzzy | image | path, fuzzy, x1, y1, x2, y2, trans? | x,y | 区域+精度 | lua/ziyan_engine/color.lua | done | 区域+精度 |
| imageWidth | image | path | number | 图宽 | (see module backend) | planned | 图宽 |
| imageHeight | image | path | number | 图高 | (see module backend) | planned | 图高 |
| imageFilter | image | path, colors, fuzzy? | bool | 颜色过滤 | (see module backend) | planned | 颜色过滤 |
| imageBinarization | image | path, threshold | bool | 二值化 | (see module backend) | planned | 二值化 |
| imageResize | image | path, w, h | bool | 缩放 | (see module backend) | planned | 缩放 |

## ocr — OCR / 识字

- backend: `lua/ziyan_engine/py_cv.lua + /usr/lib/ziyan/bin/ziyan_ocr (Vision)`
- count: 8（done 4 / partial 4 / planned 0）

| 函数名 | 模块 | 参数 | 返回值 | 含义 | 实现位置 | 状态 | 备注 |
|---|---|---|---|---|---|---|---|
| getText | ocr | x, y, x1, y1 | text, numbers | 区域文字+数字 | lua/ziyan_engine/py_cv.lua | done | 区域文字+数字；别名: pyGetText, readText |
| strFind | ocr | x, y, x1, y1 | string | 区域识字 | lua/ziyan_engine/py_cv.lua | done | 区域识字；别名: pyStrFind |
| findStr | ocr | str, x, y, x1, y1 | x,y | 找文字位置 | lua/ziyan_engine/py_cv.lua | partial | 找文字位置；别名: pyFindStr |
| findNumber | ocr | x, y, x1, y1 | number\|nil | 区域数字 | lua/ziyan_engine/py_cv.lua | partial | 区域数字；别名: pyFindNumber |
| localOcrText | ocr | tessdata, lang, x, y, x1, y1, wl? | string | 本地 tess 接口（可选） | lua/ziyan_engine/py_cv.lua | partial | 本地 tess 接口（可选） |
| cloudOcrText | ocr | user, pass, softid, x, y, x1, y1 | string | 云 OCR（可选配置） | lua/ziyan_engine/py_cv.lua | partial | 云 OCR（可选配置） |
| ZiYanCV.ocr_backends | ocr |  | table | 可用后端列表 | lua/ziyan_engine/py_cv.lua | done | 可用后端列表 |
| ZiYanCV.capture_region | ocr | x, y, x1, y1, path? | table | 裁剪区域图 | lua/ziyan_engine/py_cv.lua | done | 裁剪区域图 |

## app — 应用管理

- backend: `lua/ziyan_engine/app.lua`
- count: 6（done 2 / partial 1 / planned 3）

| 函数名 | 模块 | 参数 | 返回值 | 含义 | 实现位置 | 状态 | 备注 |
|---|---|---|---|---|---|---|---|
| appRun | app | bid:string | bool | 启动 App，bid 作者填写 | lua/ziyan_engine/app.lua | done | 启动 App，bid 作者填写；别名: runApp, pyOpenApp, open_app |
| appKill | app | bid:string | bool | 结束 App | lua/ziyan_engine/app.lua | done | 结束 App；别名: closeApp, pyCloseApp, close_app |
| appRunning | app | bid:string | bool | 是否在跑 | lua/ziyan_run.lua | partial | 是否在跑；别名: appIsRunning |
| frontAppBid | app |  | string | 前台 Bundle ID | (see module backend) | planned | 前台 Bundle ID |
| appBundlePath | app | bid | string | 包路径 | (see module backend) | planned | 包路径 |
| appDataPath | app | bid | string | 数据路径 | (see module backend) | planned | 数据路径 |

## file — 文件 / PLIST

- backend: `lua/ziyan_engine/{io_fs,py_cv}.lua`
- count: 10（done 10 / partial 0 / planned 0）

| 函数名 | 模块 | 参数 | 返回值 | 含义 | 实现位置 | 状态 | 备注 |
|---|---|---|---|---|---|---|---|
| FileExists | file | path | bool |  | lua/ziyan_engine/py_cv.lua | done | 别名: file_exists |
| FileCreate | file | path, content?, is_dir? | bool |  | lua/ziyan_engine/py_cv.lua | done |  |
| FileCopy | file | src, dst | bool |  | lua/ziyan_engine/py_cv.lua | done | 别名: fileCopy |
| FileDelete | file | path | bool |  | lua/ziyan_engine/py_cv.lua | done |  |
| FileMove | file | src, dst | bool |  | lua/ziyan_engine/py_cv.lua | done |  |
| FileList | file | path, recursive? | table |  | lua/ziyan_engine/py_cv.lua | done |  |
| readFileString | file | path | string |  | lua/ziyan_engine/io_fs.lua | done |  |
| writeFileString | file | path, content | bool |  | lua/ziyan_engine/io_fs.lua | done |  |
| PlistRead | file | path | table\|nil |  | lua/ziyan_engine/py_cv.lua | done | 别名: plistRead |
| PlistWrite | file | path, data | bool |  | lua/ziyan_engine/py_cv.lua | done | 别名: plistWrite |

## net — 网络 / FTP / 时间

- backend: `lua/ziyan_engine/py_cv.lua (curl)`
- count: 8（done 6 / partial 1 / planned 1）

| 函数名 | 模块 | 参数 | 返回值 | 含义 | 实现位置 | 状态 | 备注 |
|---|---|---|---|---|---|---|---|
| NetTime | net | timeout? | string | 网络时间 YYYY-mm-dd HH:MM:SS | lua/ziyan_engine/py_cv.lua | done | 网络时间 YYYY-mm-dd HH:MM:SS；别名: NetTimeStr, getNetTime |
| NetIp | net | timeout? | string | 外网 IP | lua/ziyan_engine/py_cv.lua | partial | 外网 IP；别名: getNetIP, net_ip |
| httpGet | net | url, timeout? | string | HTTP GET | (see module backend) | planned | HTTP GET |
| FtpUpload | net | host, user, pass, local, remote, port?, timeout? | table |  | lua/ziyan_engine/py_cv.lua | done | 别名: ftp_upload |
| FtpDownload | net | host, user, pass, remote, local, port?, timeout? | table |  | lua/ziyan_engine/py_cv.lua | done |  |
| FtpDelete | net | host, user, pass, remote, port?, timeout? | table |  | lua/ziyan_engine/py_cv.lua | done |  |
| FtpRead | net | host, user, pass, remote, port?, timeout? | table |  | lua/ziyan_engine/py_cv.lua | done |  |
| FtpIsUpdate | net | host, user, pass, remote, local?, port?, timeout? | table |  | lua/ziyan_engine/py_cv.lua | done |  |

## codec — 编解码

- backend: `lua/json.lua + 自研封装`
- count: 6（done 2 / partial 0 / planned 4）

| 函数名 | 模块 | 参数 | 返回值 | 含义 | 实现位置 | 状态 | 备注 |
|---|---|---|---|---|---|---|---|
| jsonEncode | codec | t | string | 安全编码 | lua/ziyan_engine/codec.lua | done | 安全编码 |
| jsonDecode | codec | s | any\|nil | 空串不抛错 | lua/ziyan_engine/codec.lua | done | 空串不抛错 |
| aesEncrypt | codec | s, key | string |  | (see module backend) | planned |  |
| aesDecrypt | codec | s, key | string |  | (see module backend) | planned |  |
| md5String | codec | s | string |  | (see module backend) | planned |  |
| md5File | codec | path | string |  | (see module backend) | planned |  |

## memory — 内存缓存 / Hook 读名（自研，非 TE）

- backend: `lua/ziyan_engine/py_cv.lua + ziyan_mem / AppTouch MemHook`
- count: 7（done 4 / partial 3 / planned 0）

| 函数名 | 模块 | 参数 | 返回值 | 含义 | 实现位置 | 状态 | 备注 |
|---|---|---|---|---|---|---|---|
| MemoryAccess | memory | bid, key | string | 优先读缓存 plist | lua/ziyan_engine/py_cv.lua | done | 优先读缓存 plist |
| MemoryWrite | memory | bid, key, value | bool | 写缓存 | lua/ziyan_engine/py_cv.lua | done | 写缓存 |
| MemoryKeys | memory | bid | table |  | lua/ziyan_engine/py_cv.lua | done |  |
| MemoryDump | memory | bid, max? | table |  | lua/ziyan_engine/py_cv.lua | done |  |
| MemoryFind | memory | bid, query | table | 角色/排行榜/背包等 | lua/ziyan_engine/py_cv.lua | partial | 角色/排行榜/背包等 |
| MemoryRoleName | memory | bid, hint? | string |  | lua/ziyan_engine/py_cv.lua | partial |  |
| MemoryScanNames | memory | bid | table |  | lua/ziyan_engine/py_cv.lua | partial |  |

## control — 运行控制（音量菜单协同）

- backend: `lua/ziyan_engine/control.lua + ZiYanVol tweak`
- count: 2（done 2 / partial 0 / planned 0）

| 函数名 | 模块 | 参数 | 返回值 | 含义 | 实现位置 | 状态 | 备注 |
|---|---|---|---|---|---|---|---|
| ziyan_pause_point | control |  | void | 检查暂停/停止标志 | lua/ziyan_engine/control.lua | done | 检查暂停/停止标志 |
| __ZIYAN_wait_while_paused | control |  | void | 内部：暂停自旋 | lua/ziyan_engine/color.lua | done | 内部：暂停自旋 |

## orient — 坐标系 / init

- backend: `lua/ziyan_engine/orient.lua + ZiYanOrientMap.h`
- count: 4（done 4 / partial 0 / planned 0）

| 函数名 | 模块 | 参数 | 返回值 | 含义 | 实现位置 | 状态 | 备注 |
|---|---|---|---|---|---|---|---|
| init | orient | 0\|1\|2 | bool | Home 下/右/左 | lua/ziyan_engine/orient.lua | done | Home 下/右/左 |
| ZiYanOrient.to_phys | orient | x, y | px,py | 逻辑→物理 | lua/ziyan_engine/touch.lua | done | 逻辑→物理 |
| ZiYanOrient.to_logic | orient | px, py | x,y | 物理→逻辑 | lua/ziyan_engine/color.lua | done | 物理→逻辑 |
| ZiYanOrient.logical_size | orient |  | w,h |  | lua/ziyan_engine/orient.lua | done |  |

## 兼容别名

### 触动 TS → ZiYan（`api_spec/compat/ts_to_ziyan.json`）

| TS | ZiYan |
|---|---|
| `runApp` | `appRun` |
| `closeApp` | `appKill` |
| `appIsRunning` | `appRunning` |
| `unlockDevice` | `deviceUnlock` |
| `getScreenSize` | `getScreenResolution` |
| `snapshot` | `snapshot` |
| `nLog` | `logDebug` |
| `sysLog` | `logDebug` |
| `lua_exit` | `scriptStop` |
| `ocrText` | `getText` |
| `findMultiColorInRegionFuzzy` | `findMultiColorInRegionFuzzy` |
| `mSleep` | `mSleep` |
| `toast` | `toast` |
| `tap` | `tap` |

### TE modular → ZiYan（`api_spec/compat/te_modular_to_ziyan.json`）

| TE | ZiYan |
|---|---|
| `sys.toast` | `toast` |
| `sys.dialog` | `notifyMessage` |
| `sys.log` | `logDebug` |
| `sys.sleep` | `mSleep` |
| `sys.input` | `inputText` |
| `sys.clip.copy` | `copyText` |
| `sys.clip.text` | `clipText` |
| `sys.lock.unlock` | `deviceUnlock` |
| `screen.getColor` | `getColor` |
| `screen.getColorRGB` | `getColorRGB` |
| `screen.findColor` | `findMultiColorInRegionFuzzy` |
| `screen.findImage` | `findImageInRegionFuzzy` |
| `screen.snapshot` | `snapshot` |
| `screen.keep` | `keepScreen` |
| `screen.rotate` | `rotateScreen` |
| `touch.down` | `touchDown` |
| `touch.move` | `touchMove` |
| `touch.up` | `touchUp` |
| `key.down` | `keyDown` |
| `key.up` | `keyUp` |
| `app.run` | `appRun` |
| `app.kill` | `appKill` |
| `app.running` | `appRunning` |
| `ocr.tess.ocr` | `localOcrText` |
| `net.http.get` | `httpGet` |
| `net.ftp.get` | `FtpDownload` |
| `net.ftp.put` | `FtpUpload` |
| `codec.json.encode` | `jsonEncode` |
| `codec.json.decode` | `jsonDecode` |
| `file.plist.read` | `PlistRead` |
| `file.plist.write` | `PlistWrite` |
| `file.copy` | `FileCopy` |
| `script.stop` | `scriptStop` |

## 内部非脚本 API（ObjC 简表）

| 符号/类 | 路径 | 职责 |
|---|---|---|
| `ZiYanScreenBridge` | `objc/tweak/springboard/ZiYanScreenBridge.m` | 截屏/找色/dump/HID+图标点击 |
| `ZiYanToastBridge` | `objc/tweak/springboard/ZiYanToastBridge.m` | Toast IPC |
| `Tweak (ZiYanVol)` | `objc/tweak/springboard/Tweak.m` | 音量键菜单、启动 ScreenBridge |
| `ZiYanAppTouch` | `objc/tweak/apptouch/ZiYanAppTouch.m` | 进程内触控注入 |
| `ZiYanMemHook` | `objc/tweak/apptouch/ZiYanMemHook.m` | 内存名 Hook |
| `ZiYanEngine` | `objc/shared/ZiYanEngine.m` | 引擎就绪/运行状态 |
| `ZiYanScriptRunner` | `objc/shared/ZiYanScriptRunner.m` | 脚本启动器写入 |
| `ZiYanOrientMap` | `objc/shared/ZiYanOrientMap.h` | 逻辑↔缓冲/HID 归一化 |
| `ZiYanPaths` | `objc/shared/ZiYanPaths.h` | 路径常量 |
| `ZiYanTouchBridge` | `objc/shared/ZiYanTouchBridge.m` | 共享触控桥（历史/备用） |
| `ZiYanHID (archive)` | `objc/_archive/ZiYanHID.m` | 未接入构建 |

## Script SDK（阶段 7.35）

- 用户层目录：`Script/{Template,Examples,Helper,Debug}`
- 实现：`lua/modules/Script.lua`（`generate` / `debug` / `validate` / `sdkRoot`）
- 契约：`api_spec/modules/script_sdk_contract.lua`
- 坐标：`Helper.tap(x,y)` = **设计坐标**（`Touch.tapDesign`），禁止物理 `Touch.click`

| 函数名 | 中文 | 参数 | 返回值 | 状态 |
|---|---|---|---|---|
| Script.generate | 生成脚本 | need:string, opts?:table | ok, path [, body] | done |
| Script.debug | 调试快照 | opts?:table | table | done |
| Script.validate | 环境/代码校验 | opts?:table | ok, report | done |
| Script.sdkRoot | SDK 根路径 | — | string | done |
| Helper.tap | 设计坐标点击 | x,y [,hold] | bool,... | done |
| Helper.tapRatio | 比例点击 | rx,ry [,hold] | bool,... | done |
| Helper.findColor | 找色 | 同 Image.findColor | x,y | done |
| Helper.findText | 找字 | word [,区域] | x,y,via | done |

模板：`auto_click` / `find_color` / `ocr` / `login` / `loop_task` / `state_machine`。

示例：`Script.generate("每天自动领取奖励")` → `scripts/generated/gen_*.lua`。

## Optimization 2.0（阶段 7.6.2）

- 实现：`lua/modules/Optimization.lua`（2.0.0）+ `IssueClassifier` / `OptimizationAdvisor` / `OptimizationRollback`
- 契约：`api_spec/modules/optimization_contract.lua`
- 历史库：`Media/ZiYan/opt/optimization_history.jsonl`
- 默认：**proposal 模式**（须 `human_confirm` 才 apply；禁止自动改 Touch/Coordinate 等核心）
- 闭环：`collect → detect → classify → analyze → propose → human_confirm → apply → verify → record`

| 函数名 | 中文 | 参数 | 返回值 | 状态 |
|---|---|---|---|---|
| Optimization.cycle | 闭环 | goal, opts? | table | done |
| Optimization.recordHistory | 记历史 | entry | table | done |
| Optimization.classify | 分类 | issue | table | done |
| IssueClassifier.classify | 问题分类 | issue | table | done |
| OptimizationAdvisor.advise | 优化建议 | issue, analysis?, cls?, patch? | proposal | done |
| OptimizationAdvisor.confirm | 确认建议 | id, accepted? | bool,... | done |
| OptimizationRollback.snapshot | 快照 | meta? | id,dir,info | done |
| OptimizationRollback.restore | 回滚 | snapshot_id | ok,n | done |

示例：

```lua
local r = Optimization.cycle("领奖优化", {
  force_issue = "phase_stuck",
  device = "192.168.31.53",
  -- 默认停在 proposal；确认后 apply：
  human_confirm = true,
  light_test = true,
})
```

真机验收仅第二类设备：`.53` / `.166`（见 `DEVICE_RULES.md`）。

## power / thermal

当前 `catalog.json` 无独立 power/thermal 模块；若后续规划，以 planned 追加，不在此臆造 done API。
