# 触摸精灵 5.1.2 deb 全量分析 → 子砚可学 / 可仿 / 可超越计划

**分析对象**：`/Users/mac/Desktop/deb分析/触摸精灵5.1.2/deb_extracted`  
**包元数据**：`com.dqpxgctsh.iexveqrfvwjs` · 显示名 `blhjdrag` · `Version: 5.1.2-1-3` · touchelf.com  
**约束（硬）**：只作原理/架构对照；**禁止**复用、导入、调用触动任何模块/符号/源码；全部用 **ZiYan 自有 API** 重做。  
**并表**：与 `SURPASS_PLAN_171_53_166.md`、现场 118 稳态刀互补——本文件偏「产品骨架」，那份偏「内存/合帧数值」。

---

## 0. 包内全量清单（83 文件 / 24 目录）

### 0.1 控制脚本 `control/`

| 文件 | 作用 | 对子砚启发 |
|------|------|------------|
| `control` | 依赖 `mobilesubstrate`；Installed-Size≈29MB | 单包体量大=能力进 Daemon |
| `preinst` | **升级前清空** `/var/touchelf/var/www/*` | 升级只清 Web 缓存，**不 rm 用户脚本**（我们对齐：禁 prerm 毁脚本） |
| `postinst` | kill 旧 daemon/editor/proxy；chmod +s daemon；`uicache`；SB reload | 安装后单一守护重启；setuid 保 root 能力 |
| `postrm` | kill tedaemon/teeditor/teproxy | 卸载干净杀进程 |

### 0.2 数据层四大块 `data/`

| 路径 | 体量 | 角色（去混淆后） |
|------|------|------------------|
| `bin/wnriakwyww` | **~24.9MB** fat armv7+arm64 | **主脑 Daemon**（≈ TSDaemon）：Lua+OpenCV+Tesseract+截屏+HTTP |
| `bin/wnriakwyww.dylib` | ~136KB | Daemon 旁路 dylib（Substrate + HTTP:7780） |
| `bin/wnriakwyww.plist` | 0 字节 | 占位/空（非 LaunchDaemon 正文） |
| `Library/.../qaprykg.dylib` | ~781KB fat+arm64e | **MS Tweak**：注入 SB / backboardd / wifid |
| `Library/.../qaprykg.plist` | Filter | Bundles=`springboard`,`backboardd`；Exec=`wifid` |
| `Applications/zruettjaau.app/` | App~216KB + 图标 | **薄壳 App**（WebKit → 本机 Web UI） |
| `var/touchelf/scripts/` | 空 | 用户脚本目录（安装时不带业务脚本） |
| `var/touchelf/var/lib/` | Lua 库 | telib + luasocket/luasec/json/inspect |
| `var/touchelf/var/www/` | React SPA | 本机编辑器/控制台（Monaco） |
| `var/touchelf/var/{log,tmp,ui}` | 空目录 | 运行态落盘位 |

**架构一句话**：App 只是入口；**找色/OCR/触控/脚本全在 Daemon**；SB/backboard **只做 HUD+HID+看门狗**，不背 OpenCV。

---

## 1. 逐块能力画像（strings / otool / Lua）

### 1.1 Daemon `wnriakwyww`（可学重心）

**链接框架**：UIKit、QuartzCore、AVFoundation、GraphicsServices、SpringBoardServices、**IOKit、IOMobileFramebuffer、IOSurface**、sqlite、zlib、libc++；并链 `/bin/wnriakwyww.dylib`。

**内嵌引擎（字符串实锤）**：
- Lua **5.2.2**（进程内 `lua_State`，非独立 lua 进程）
- **OpenCV 4.2.0**（静态进包 → 体积暴涨）
- **Tesseract 3.03**（local OCR / hOCR）
- cpp-httplib、LuaSec、TIFF 等

**截屏路径**：`createScreenIOSurface`、`IOSurface`/`IOMobileFramebuffer` —— 与 .171 观察「IOSurface 常驻 ~5.76MB」一致。

**Lua 原生下划线 API（telib 所调）**：  
`_getColor` `_findColor` `_findImage` `_snapshot` `_toast` `_message` `_log`  
`_localOcrText` `_localOcrTextEx` `_fontInit` `_fontFindText` `_fontOcrText`  
`_imageFilter` `_plistRead` `_plistWrite`  
以及缓冲：`_allocateBufferEntry` `_releaseBufferEntry`、`keepScreen`。

**HTTP API 痕迹**：`/api/screen/snapshot`；WebSocket 样例 `ws://…:9000`；App 打开 `http://127.0.0.1:8000/ui`。

### 1.2 MS Tweak `qaprykg.dylib`

- 三中心日志：`backboard center` / `springboard center` / `watchdog center`
- 触控：`IOHIDEventSystemClientDispatchEvent`、`handleTouch:`、`BackBoardHook`
- Toast：嵌入 **MBProgressHUD**（SB 侧显示）
- IPC：`CFMessagePort` 回调（SB↔Daemon 消息口，而非狂写文件）
- Filter 含 **wifid**：保活/网络侧挂钩（子砚可评估是否必要，默认不做）

### 1.3 App `zruettjaau`

- 极薄：UIKit + WebKit → `http://127.0.0.1:8000/ui`
- 职责=启动 Web 控制台，不跑找色

### 1.4 `telib.lua`（脚本兼容层）

薄封装：多点色 / 找图 / toast / mSleep(socket.sleep) / OCR / fontOCR / httpGet/ftp / json / plist。  
**真逻辑在 Daemon C++**；Lua 只做参数整形与 JSON。

### 1.5 `var/www` Web UI

React 产物；路由含：`/run` `/script` `/script/stop` `/api` `/config` `/record` `/system/{apps,log,reboot,respring}` `/ui/settings/snapshot` 等。  
= **本机 IDE + 运行控制台**（Monaco `editor.worker.js`）。

### 1.6 第三方 Lua（可忽略抄袭）

`socket.*` / `ssl` / `json` / `inspect` / `options.lua`(LuaSec 生成器) —— 开源生态，子砚可自选等效库，**不要从本包抠二进制依赖**。

---

## 2. 与子砚现状对照（学什么 / 别学什么）

| 维度 | 触动 5.1.2 | 子砚现状 | 结论 |
|------|------------|----------|------|
| 宿主 | **单 Daemon 巨石**（CV+OCR+Lua） | framecap embed + 多 tweak | 架构已偏 TS；继续收敛，勿再加进程 |
| 帧 | **IOSurface 进程内常驻** | 文件 shm（@2≈2.8MB / @3≈10.5MB） | 学「常驻一块缓冲」；可用自有 shm/IOSurface，禁抄符号 |
| SB 职责 | HUD+HID+看门狗，**无 OpenCV** | 合帧/relay 仍易搅局 | **SB 极薄**（R6） |
| IPC | CFMessagePort 为主 | 文件旗/shm 偏多 | 学「少文件风暴」；自研 ControlShm/端口 |
| 脚本 API | telib 薄封装 → `_xxx` | Zy.* / findMulti… | **语义对齐、实现自有** |
| OCR | 包内 Tesseract 3 | Vision/`ziyan_ocr` | 可继续 Vision；可选开源 Tesseract（Apache）自建，不搬 TS 包内 |
| 找图/滤波 | OpenCV 进 Daemon | 部分自有/ncnn | 评估轻量 OpenCV 模块或自研，控体积 |
| UI | 本机 Web IDE :8000 | App Overlay + 音量菜单 | **可超越点**：Web IDE/远程编辑 |
| 日志 | 起停极少 | 曾多旗风暴 | 已部分修；保持「热路径零盘」 |
| 升级 | 只清 www | 曾误删脚本 | 已修方向；写进门禁 |

---

## 3. 计划分层：能借鉴 / 能模仿 / 能超越

> 「借鉴」= 架构原则；「模仿」= 行为与门禁对齐；「超越」= TS 弱/无而我们可做强。  
> 全部 **ZiYan 重实现**，不出现触动函数名/模块名/二进制复用。

### A. 立刻可做（对齐稳态 · 接现有 R1–R4）

| ID | 动作 | 门禁 |
|----|------|------|
| A1 | **热帧一块常驻**：running 期间固定缓冲；禁业务中 clear；@3 预算≤~6MB（R2） | .53 shm/phys 不爬；切前台无 serve_force 连打（118 已开刀） |
| A2 | **SB 极薄**：找色永不进 SB；toast 只走轻量桥；relay 仅切屏/空帧 | 业务 find_ms 不随 SB CPU 线性恶化 |
| A3 | **脚本 API 薄封装层**：Lua 只整形；C 扫热缓冲（学 telib 分层，不抄 telib） | Desktop ios7/ios8p 语义门禁绿 |
| A4 | **启停单一会话**：换脚本不杀 Daemon；空闲不 soft_kill（116/118） | 音量 20 次 pid 不变 |
| A5 | **真实 find_ms**：禁 color_perf=0.0 | 窄 ROI p50≤40ms（对标 TS hist） |

### B. 中期模仿（产品能力面）

| ID | 动作 | 说明 |
|----|------|------|
| B1 | **本机控制 HTTP 面**（已有 :50005 苗头）收敛为：status / snapshot / run / stop / log | 对齐 TS Web 路由「职责」而非路径抄袭 |
| B2 | **keepScreen 语义**：锁热帧多次 find，不催帧 | 已有雏形，做成脚本可测契约 |
| B3 | **找图 + 简单滤波**：自有实现或可选开源 OpenCV（注明许可证），进 framecap 同进程 | 体积门禁：rootful 增量可控 |
| B4 | **OCR 双通道**：Vision 默认；可选本地 tessdata（用户自备，Apache 引擎自编） | USB/LAN getText 门禁 |
| B5 | **CFMessagePort 级 IPC 收敛**：高频路径禁止「每圈写多个旗文件」 | 100s TINY/RSS 锁死（.166 已接近） |

### C. 超越项（TS 弱或无）

| ID | 超越点 | 验收 |
|----|--------|------|
| C1 | **闲时更省**：停脚本后释帧；TS Daemon 常驻 IOSurface+巨石 | 闲 CPU≤2.5%、shm≤128KB |
| C2 | **rootless+rootful 同语义** | 四机同一门禁脚本 |
| C3 | **可观测一键报告**：CPU/RSS/TINY/find_ms/relay；TS 几乎无 | 对得上 171 对照表 |
| C4 | **前台门闩 / 假命中更严** | 桌面 0 假「登录」；游戏命中不降 |
| C5 | **Web IDE 轻量版**（可选）：脚本编辑+运行，不嵌 25MB OpenCV 进 App | App 仍薄；Daemon 承重 |
| C6 | **抓色器≡业务门禁**（Phase1 已有）持续硬化 | picker↔biz 永绿 |

---

## 4. 明确禁止（防「抄袭式翻车」）

1. 不拷贝 `wnriakwyww` / `qaprykg` / `telib.lua` / www 产物进工程或设备当依赖。  
2. 不复用混淆名、`com.touchelf.*` 消息口、触动原生 Lua API 名做实现入口。  
3. 不把 OpenCV/Tesseract **从该 deb 抽出**链接；若采用开源引擎，走官方源码+许可证。  
4. 未过 G0（171 对照）不对外宣称「已超越触动」。

---

## 5. 建议落地顺序（与现网刀合并）

```
已完成：Phase1 语义门禁 · R1-118（切前台/serve_force）
  ↓
P0  R2  @3 帧预算 + running 热帧契约
P1  R3  TINY 肥/爬（.166 基线肥 / .53 爬）
P2  R4  find_ms 真实埋点 + 假命中
P3  A2/B5 SB 极薄 + IPC 减文件风暴
P4  B1/B2 控制面/keepScreen 契约文档化+门禁
P5  B3/B4 找图/OCR 增强（按需）
P6  C1–C6 超越项（对照表全绿后）
```

---

## 6. 一页结论

触摸精灵 5.1.2 的「稳」来自：  
**单 Daemon 扛 Lua+帧+CV · IOSurface 常驻 · SB 只做触控/HUD · Web 薄壳 · 热路径几乎不打日志。**

子砚要超越：  
**先对齐这块骨架与数值（帧/IPC/SB/find_ms），再用 rootless、闲时释帧、可观测、抓色器门禁拉开差距——全部自研重做，不搬包内二进制。**
