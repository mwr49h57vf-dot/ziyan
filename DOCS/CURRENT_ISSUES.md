# ZiYan 当前问题账本（唯一当前真相）

最后更新：2026-08-17 21:29（本地 git 基线 `3e5ded6` 已提交，未部署；P2 两门 PASS 保持；SAME_FRAME 设计+双包均为 PASS_READY_FOR_DEPLOY；COLOR_PICKER_CONTRACT 仍 FAIL；禁宣称超越/发布）  
维护规则：每次修改、部署或测试结束后必须更新本文件；历史报告只作为证据，不得覆盖这里的当前判定。

## 0. 当前结论

- **本地 git 回滚基线（2026-08-17，源码快照，未部署）**：`3e5ded63d761c65c0af83fe3617a1f5cfdffdd84`。父提交 `7a37c92ee343a401457929b7955af1eeaba59174`。这是工作树收口，不是四机验收通过。
- **P2（2026-08-17，不得回写成失败）**：`P2_HOME_FRAME_LEASE=PASS`，`P2_STALE_GAME_FRAME_REJECT=PASS`，`FC_N=1`。证据 `tmp_shots/P2_HOME_COMMIT_NO_FINGERPRINT_4PHONE_20260817_190812/VERDICT.md`。
- **COLOR_PICKER_SAME_FRAME_DESIGN**：`PASS_READY_FOR_DEPLOY`。证据 `tmp_shots/COLOR_PICKER_SAME_FRAME_DESIGN_20260817_205327/VERDICT.md`。
- **COLOR_PICKER_SAME_FRAME_BUILD（本轮，未部署）**：`COLOR_PICKER_SAME_FRAME_BUILD=PASS_READY_FOR_DEPLOY`。rootful `…-3+debug` SHA256 `3d3b8cd0da11872e3d02731634ab477340e9b9d7b1fb78effb49c16b03e8a694`，framecap `/usr/lib/ziyan/bin/ziyan_framecap` SHA256 `bbed80fbaaf3c413d61749b34df335618fd0340b5310564272c61ebe1950c01a`。rootless `…-4+debug` SHA256 `0a65de892eec02a6683e54fbd68cb56a6deb1b8eb2abdc8a982eb981e3673408`，framecap `/var/jb/usr/lib/ziyan/bin/ziyan_framecap` SHA256 `df33f2c78e552ae1f3b7f00122ebfb25a797dec3d5d62334bdc2da4ae6f11b83`。canonical MapRead 符号已链接；HTTP 源无 CARenderOnly/force_recap 写入；未新增第二 framecap。证据 `tmp_shots/COLOR_PICKER_SAME_FRAME_BUILD_20260817_210115/VERDICT.md`。未改 P2 Commit、matcher、ROI、fuzzy。
- **COLOR_PICKER_CONTRACT**：真机尚未装本刀。`COLOR_PICKER_CONTRACT=FAIL`，`P2_COLOR_CORE=BLOCKED`。
- 禁止宣称完全兼容 / 超过触动精灵 / 全部函数稳定。


- **双包**：`debug-10-24-5` rootful + `debug-10-24-6` rootless，各 52MB。四机已装。BBFrame OFF。
- **Z1-VIS**：`RUN1_GATE_20260815_121431_all_72725` 四机设备端 `BUSINESS_PASS`。
- **Z1-MEM**：本包 30min 四机 PASS `tmp_shots/Z1_MEM_C98_20260815_134508/REPORT.md`。不得再写「Z1-MEM 仍未完成」。不是 Z2。
- **Z1-TOUCH / Z1-ASSET**：本包四机 PASS。证据 `tmp_shots/Z1_TOUCH_20260815_144118`、`tmp_shots/Z1_ASSET_20260815_144305`。
- **Z1-OCR**：门禁已跑，数字/多行 miss，Lua getText 超时。不得写成 OCR 稳定。
- **Z1-NET**：隔离完成。`.53` FTP 通；rootful `curl` 127。本地核心仍 `FC_N=1`。
- **Z2-10M-PRELIM**：`tmp_shots/Z1_MEM_C98_20260815_144705` 四机 PASS。**不是最终 Z2**。
- **forever**：已停，不得重启。`usb_play=ERR` `lan_play=ERR` 是该循环夹具。
- **观察机**：`.149/.171` 本窗密钥可达，只读。不可达时标 `OBSERVER_UNREACHABLE`，不得写成 ZiYan FAIL。
- 禁止宣称完全兼容 / 完美运行 / 全部函数稳定 / 超越触动 / 可正式发布。
- **RUN1 通道**：密钥 SSH 禁止 `-n`；设备端 `Media/ZiYan/verdicts/<run_id>.txt`。
- 项目尚未完成，尚不能宣称超过触动精灵。
- **本刀 debug-10-24**：脚本 Toast 底边 pad 固定 14pt，不读 `safeAreaInsets`。音量菜单仍走旧公式。未改找色 / ios7.lua / 金标。
- **现包 debug-10-24**：SHA256 `62661916bc7445e0434df16a71826ca3f7f3d3f53b5b851accc8dea9e32944f6`。ios7.lua 三机已再开。
- **烟测 `.166`**：游戏 `label.y=276`（raw=568×320）；Home `label.y=276`（raw=320×568）。10-23 时 Home 是 262。X 变是文案变宽，仍居中。
- **回滚 10-23**：`.101` `..._20260815_093829`；`.166` `..._093952`；`.112` `..._094141`。
- **`.171` 只读**：TSDaemon pid **555**，etime ~6d。未部署。
- **用户（09:26）**：感觉桌面 SB 开 App 瞬间，找色也会像 Toast 一样偏。
- **密采** `tmp_shots/TS_OBS/FIND_Y_TRANS_20260815_0926/REPORT.md`：同一画面像素 **dy=0**；命中仍是 `(1010,294)`。人眼偏差来自 Toast 跳 14pt + 换画面 + `last_find` 晚 1～2 拍 + 合帧 40ms。不是找色跟 safe area 滑坐标。未改代码。
- **用户（09:13）**：触动 Toast 永远停在 init 位置；子砚方向对，但 SB 跑 App 时有上下偏差。先采 `.171` 再采 `.166`，并看找色是否同样偏。
- **采证** `tmp_shots/TS_OBS/TOAST_Y_20260815_0913/REPORT.md`：触动 Home/登录 Toast init-Y 几乎不动。子砚游戏 `label.y=276`、切 Home `262`（14pt）。找色命中仍是 `(1010,294)`，**找色不跟 Toast 一起偏**。根因：Toast `bottomPad` 用了 `safeAreaInsets`，raw 竖/横会改 pad。未改代码。
- **用户（08:47 / 08:50「开始」）**：找色必须像触动：init 钉画布 + 当前屏 + 抓色器比色。禁止再加 OrientMap/前台门/pixel_format/lease 分支。
- **本刀 debug-10-23**：缓冲已是 init 画布（`1136×640`、bpr≥w*4、SW/SH 对齐）时，getColor/find 直接用脚本坐标比 RGB；不建 OrientMap LUT、不扩细条 pad。竖屏原始缓冲仍走旧映射。未改 fuzzy / 金标 / ios7.lua / 像素序。
- **现包 debug-10-23**：SHA256 `a2e9d638f056cedc00b1745d145faf3acd7b5d09513654d623d8636dba2241c3`。framecap `678fb44da86ca12d0c4b34a2ba85b9cb89f4a101513788b48b0a6c0a169b19bd`。ios7.lua 三机已再开。
- **烟测**：三机均从桌面点进游戏（竖条命中）；游戏金标 `getColor(706,449)=12754024`；find cost ~2–4ms（`.166` 一针 19.6ms）；FC_N=1；lease=active。游戏前台对桌面竖条 `pixel_miss` 预期。无 10-21 式全 miss。
- **回滚 10-22**：`.101` `..._20260815_085737`；`.166` `..._085843`；`.112` `..._085949`。
- **`.171` 只读**：TSDaemon pid **555**，etime ~6d。`.149` TSDaemon pid **562**。未部署。
- **用户（08:30）**：10-21 上三机后找色全找不到。
- **根因**：10-21 合帧省掉 BGRA→RGBA，缓冲仍是 BGRA，找色按 RGBA 读，红蓝对调。Home 竖条 / 游戏金标全部 miss。`.101` 当时 `getColor(706,449)=6966783`，不是金标。
- **本刀 debug-10-22**：恢复写成 RGBA（uint32 换 R/B，不再逐字节）。节拍优化保留。ios7 已能从桌面点进游戏。金标回到 `12754024`（与 10-18/10-20 守护 IOSurface 一致，不是 AppWindow 的 12688231）。
- **现包 debug-10-22**：SHA256 `310ff75ea7dd0ea74a4dd747950126b4bdbc351188ff0ec569e397a066c29c94`。ios7.lua 三机已再开。
- **回滚 10-21**：`.101` `..._20260815_083556`；`.166` `..._083645`；`.112` `..._083742`。
- **用户（08:05）**：10-20 眼观已很接近触动。10-21 颜色刀回滚，节拍还在。
- **回滚 10-20**：`.101` `..._20260815_082234`；`.166` `..._20260815_082340`；`.112` `..._20260815_082448`。
- **部署后 Home 烟测**：uisurface `.101` 70–167ms、`.166` 102–140ms、`.112` 104–120ms（装包前 `.112` 仍有秒级旧日志）。金标未在游戏前台复测。禁宣称超越。
- **上一刀 debug-10-20（刀 A）**：Home 也走守护 IOSurface，不再清零 provider=9。用户确认接近触动。SHA256 `cea265eee090c8b325dbbb5f0f02cb19283a92f9ad943bdb011cc87273b53c4b`。
- **回滚 10-19**：`.101` `..._20260815_030123`；`.166` `..._20260815_030227`；`.112` `..._20260815_030334`。
- **部署后烟测**：三机 FC_N=1、lease=active、find cost ~2ms、`pixel_miss`（游戏前台对桌面竖条，预期）。`.166` Home 失败日志已是 `fallback=current_screen` 不是清零 9。`.112` 合帧仍可 >1s（刀 B）。金标未收。
- **`.171` 只读**：TSDaemon pid **555**，etime ~5d 18h。未部署。
- **用户（02:38）**：触动仍更快。`.166` 手切 Home/回游戏，找色跟手明显慢约 2～3 倍。要求先采 `.171`+三机再出方案。
- **对照窗** `tmp_shots/TS_OBS/FIND_20260815_0238/REPORT.md`：找色 cost 中位 2ms，不是匹配器。`.166` 切 Home 后 provider 9→0→**7**，帧龄爬到 **1720ms**。根因：Home 把守护 IOSurface 当 AppWindow 清掉。
- **方案刀序**：A 本刀已上；B 减拷贝/禁 GPU 叠帧；C 金标 +1。未全绿禁宣称超越。
- **上一刀 debug-10-19**：10-18 把 provider=9 套进 AppWindow 1 秒一拍。现改守护短节拍 0.20–0.35s + Accelerator 常驻。SHA256 `7901ba1d33987eb31c6c2beb5f43ea62ffad464284f5cd667352a0f6a724f1c0`。证据 `tmp_shots/TS_OBS/FIND_20260814_2312/REPORT.md`。
- **用户（23:12）**：触动效率仍高，眼观差距小了很多。要继续对照优化。
- **上一刀 debug-10-19**：10-18 把 provider=9 套进 AppWindow 1 秒一拍。现改守护短节拍 0.20–0.35s + Accelerator 常驻。`.101` 帧龄从 ~1s 降到几十到三百毫秒；`.112` 仍有 0.4–1.4s 合帧尖刺。金标仍 12754024。证据 `tmp_shots/TS_OBS/FIND_20260814_2312/REPORT.md`。禁宣称超越。
- **现包 debug-10-19**：SHA256 `7901ba1d33987eb31c6c2beb5f43ea62ffad464284f5cd667352a0f6a724f1c0`。回滚 10-18：`.101` `..._20260814_232425`；`.166` `..._232541`；`.112` `..._232708`。
- **`.171` 只读**：TSDaemon pid **555**，`f01`。`.149` 本窗未再采。
- **上一刀 debug-10-18**：游戏前台合帧改走 framecap `createScreenIOSurface` + Accelerator，provider=**9**。成功则不进游戏主线程 `drawViewHierarchy`。三机均 `uisurface_ok`、FC_N=1、lease=active。`getColor(706,449)=12754024`（`0xC29C68`），不是历史 AppWindow 金标 `12688231`（`0xC19B67`），每通道 +1。`.112` 合帧常 >1s。证据 `tmp_shots/TS_OBS/FIND_20260814_2256/REPORT.md`。
- **现包 debug-10-18**：SHA256 `aeeb0135e4525ead125b3f0ea98604a553bc6bf29d655c47f2a49a9c00e9ef5a`。回滚 10-17：`.101` `..._20260814_225038`；`.166` `..._20260814_225156`；`.112` `..._20260814_225352`。
- **`.171` 只读（本窗）**：TSDaemon pid **555**；SB pid **70**。`.149` TSDaemon pid **562**；SB pid **69**。未部署。
- **用户确认（22:29）**：debug-10-17 第一刀（切屏废旧帧）做完。触动找色效率仍比子砚高出很多，但差距越来越小。无触动内部 find 毫秒，禁止写成「快 N 倍」。剩余差距在合帧：触动守护 `createScreenIOSurface`，子砚游戏主线程 AppWindow `drawViewHierarchy`。不拧 fuzzy。
- **现包 debug-10-17**：切前台 resident Released；find 不扫 stale/released。SHA256 `da4695af875c119eeb7170e5a6fc3f0430fc6475ee1f1f7e2cdcb464a32d55ce`。回滚 10-16：`.101` `..._20260814_221802`；`.166` `..._20260814_221920`；`.112` `..._20260814_222044`。
- **`.166` 切屏窗 21:48–21:53（debug-10-16）**：180 点。回执不再冻（last_find 最大间隔 5s，10-15 曾 41s）；`via_color_req=0`。帧龄 P95 仍 **29s**、最大 **43s**，seq 一半点不推进。找色在扫旧缓冲。证据 `tmp_shots/TS_OBS/FIND_20260814_2147/REPORT.md`。未过切屏跟手，禁宣称超越。
- **对照窗仍有效**：`tmp_shots/TS_OBS/FIND_20260814_205200/REPORT.md`。10-15 上 `.166` 近半 `reacquiring`、帧龄 P95 17.5s、回执最长 41s。
- **30min 同窗（20:03–20:33）**：`.171`+`.101/.112/.166` 同时 Home/滑屏/回 App。证据 `tmp_shots/CMP_30M_20260814_2002/REPORT.md`。触动 SB CPU 中位约 90%；子砚 `.101/.112` 约 2–5%。找色本窗几乎全 `pixel_miss`（ios7 桌面竖条 vs 游戏前台）。不是 Z2-30M 四机门禁（缺 `.53`）。
- **上一包 debug-10-15-1+debug**：SHA256 `9e6398368593d8f9015acbd735b58879d40ee8ab9b3cda19f1d4dc5c6c194144`。回滚点各机 `.../rollback/pre_...debug-10-14-1..._20260814_194835`。
- **用户纠偏（Toast 方向，19:40）**：自测机 Toast 方向与 Desktop `ios7.lua` 的 `init(1)` **反了**。`init(1)` = Home 右 = `LandscapeRight`。debug-10-14 误把 init(1) 锁成 `LandscapeLeft`（Home 左）。
- **本刀**：只对调 Toast VC 的 1/2 锁方向。不改 ios7.lua，不加 UIScreen 配方。ios7.lua 已再开。等人眼看是否还与 init 对向。
- **`.171` 只读（上一窗）**：脚本 `init("0",1)`，TSDaemon pid 555。证据 `tmp_shots/TS_OBS/20260814_1910_GESTURE/REPORT.md`。
- **10-15 时找色卡帧未改**（已由 debug-10-16 减门；游戏侧仍是 AppWindow 主线程截帧，不是触动 IOSurface）。
- **用户纠偏（Toast，19:04）**：触动不会因为用户如何改变屏幕而更改或错乱找色和 Toast。debug-10-13 肉眼 Toast 全乱套。
- **`.171` 只读（本窗）**：脚本 `init("0",1)` 自 16:54 在跑，TSDaemon pid 555 锁死。`TSToastRootViewController`：`shouldAutorotate=NO`，`supportedInterfaceOrientations=2`（LandscapeLeft）。窗尺寸来自 `_TSContextInfo` 逻辑屏，不跟 `UIScreen`。合帧 `createScreenIOSurface`，不进游戏 `drawViewHierarchy`。证据 `tmp_shots/TS_OBS/20260814_1910_GESTURE/REPORT.md`。
- **本刀 debug-10-14**：抄触动 Toast VC 锁方向；删掉 resign/background/statusBar 藏条重排。锁屏仍藏。找色卡帧 **未改**（再降 AppWindow Hz 无效；下一刀才是 Daemon IOSurface）。ios7.lua 已在 `.101/.112/.166` 再开。等人眼看滑关/最小化 Toast 是否还乱；手操卡帧预期仍在。
- **用户纠偏（Toast）**：触动不管前台 App 方向，Toast 只保持 `init` 设置。子砚此前按 `front_bid` / `UIScreen` 横竖换配方（桌面竖锁、游戏横屏 identity），肉眼会跟着 App 转。
- **上一包 debug-10-13 FAIL**：只钉 `568×320` identity，但普通 `UIViewController` 可转，且滑关会 hide+按新 UIScreen 重排。证据 `tmp_shots/TOAST_INIT_CANVAS_10_13_20260814/REPORT.md`。
- **上一刀（Toast 滑关 10-12）**：冻结上一份稳定 UIScreen 几何。用户确认滑关/最小化仍不按 init。
- **视觉函数排查（2026-08-14 18:30，只读未改代码）**：找色/找图/找字/识字 **没有** Toast 那种跟 `UIScreen` 换 overlay 配方。合帧把竖源旋进 init 画布（三机稳定态 `buf=1136×640` `orient=1`）。残留：OrientMap 仍看缓冲横竖；`ocrRoi`/daemon 找图按缓冲当逻辑坐标；OCR 5s 缓存键含 `front_bid`。证据 `tmp_shots/VISION_ORIENT_AUDIT_20260814/REPORT.md`。不是滑关连拍 VERDICT。
- **上一刀（Toast 10-11）**：10-10 竖窗钉死导致游戏里条在左侧。改为可见屏已横则横 host identity（贴 init 底边），仍竖才 ±90。不看 front_bid。
- **`.112` 找色**：仍是 Desktop 竖条色点对不上桌面，不是机型适配器。助手不改 ios7.lua。
- **用户纠偏（找色，仍有效）**：触动永远对当前屏幕找色，不看前台是哪个 App；颜色对上取色器就是命中。
- **`.112` 找色 miss 根因（2026-08-14 17:38 实采）**：不是机型适配失败（三机都是 iPhone 7、`1136×640`、`init(1)`）。ios7.lua 主搜是 `(1010,294)` 起的 **4 点竖条**。`.101`/`.166` 四点都近、find hit score=100。`.112` 只有第 1 点 `0x9A180E` 碰巧相同，296/298/300 是 `0x000049` / `0x4C004A` / 黑，find miss。游戏金标 `12688231` 三机都能取到。要过 `.112` 只能改 Desktop 色点。证据 `tmp_shots/IOS7_112_WHY_20260814`。
- **Z1-VIS 未齐**：`.53` 已恢复进验收集，尚未跑。不是四机、不是 3h。
- **P1 Day13 Gate C 30m 三机 PASS**（debug-10-2 现包，不装新包不杀 SB）：`tmp_shots/P2_30M_C98_20260814_142422`。每分钟 Home→回 App→金标 `12688231` provider=8，三机 30/30。SB/framecap/backboardd/App pid 全程不变，FC_N=1。无 PASS=0 / SSH_FAIL。停后 idle、KEEP=0、pidfile=0、embed=0、游戏前台。不是 3h、不是四机、不是 Z2。
- **P1 Day12 三机 30min PASS**（debug-10-2 现包，不装新包不杀 SB）：`tmp_shots/P0_DAY12_30M_20260814_134702`。embed 找色长稳，session 未 idle，FC_N=1，SB_CHG=0，color_req=0；停后 keep/pid/embed=0；再跑金标 `12688231 (701,447)`。OLS 中位 ≈0。不是 3h、不是四机、不是 Z2。
- **P1 Day11 100 次 run/stop 三机完成**（debug-10-2）：`tmp_shots/P0_DAY11_CYCLE_20260814_131003`。`.101` / `.112` / `.166` 均为 100/100，停后 KEEP/pid/embed=0，FC_N=1，SB pid 不变，恢复路径没有杀 SpringBoard。音量 `menu_run_trig` 典型 4/5（第一下常 miss）。崩溃后 framecap 仍在；主跑里 `.101`/`.166` 金标 miss 是 volume 后 lease=suspended，补跑唤醒后 `.101` 5s / `.112` 10s 金标 `12688231 (701,447)`。不是四机、不是 3h、不是产品全绿。
- 上一包 debug-10-5 SHA256 `6478c29a5e26d0a138424d5c84455e1834cac553abaee5c95fbb4b04b4ee7be4`。debug-10-2 SHA256 `429860055dec1e571e42b437d5879f6bb97dfb58c1d3d721e78fdc41e40b5518`。A1 标记仍在现包内。
- **P1 Day10 停止合同三机 PASS**（debug-9）：`tmp_shots/P0_DAY10_STOP_20260814_122035`。
- **P1 Day9 Ensure/health 三机 PASS**（debug-8）：`tmp_shots/P0_DAY9_HEALTH_20260814_120329`。
- **P1 Day8 session ACK 三机 PASS**（debug-7-3）：`tmp_shots/P0_DAY8_SESSION_ACK_20260814_114343`。
- provider=8 为游戏前台正确帧源；标准色 `12688231`。
- Gate C 同包 C93 三机 30m PASS；**C98 debug-3 已重跑三机 30/30 PASS**（`tmp_shots/P2_30M_C98_20260814_013438`）。未跑 `.53`。
- **C98 debug-6 三机已齐**（Day4 find 只读 resident）：`.101` / `.112` / `.166` 均为 `C-65.11-98+debug-6-1+debug`。未部署 `.53` / `.149` / `.171`。BBFrame OFF。
- debug-6 SHA256 `6bb1a90891384a0eab53aeff1a6c4a0030ba2b105430d36f96cdcdd0002bf6b4`。回滚点在各机 `.../rollback/pre_...debug-5..._20260814_082908`。
- debug-5 SHA256 `45c8e231e24ad180a2a5654b4ff2bd6d97f974550d1a0463d992fbbd37f1f77c`（上一包）。
- debug-4 SHA256 `9883d67844f666a0273a92f95c0a224740b3cf21eec2e53dd90ca9692ab8e4fe`（上一包）。
- debug-3 SHA256 `7cba2d7128c388282eef9be6b5641e9612877fbf33337112484be1972849ea35`（上一包）。
- **P3 C96 仍为 PASS**：`tmp_shots/OCR_GOLD_RUN_20260813_C96`。
- **P5 3h 仍为 C96 FAIL**（`tmp_shots/P5_3H_C96_20260813_130934_101/REPORT.md`）：`.101` 140/180、`.112` 148/180 Home 未离游戏；`.166` 180/180。不是找色。
- **C98 刀**：无 ACK 时 280ms 补一次 simulate，deadline 延到 2000ms，允许 stuck 后用 native/fg 提交。C97 `.101` 9/10 的粘游戏形态。
- **C98 Home10B 三机 10/10**：`tmp_shots/P5_C98_HOME10B_20260813`。本窗 `stuck_home=0`，走原 ACK 路径。10 轮不能代替 3h。
- `.171`/`.149`：`tmp_shots/TS_OBS/20260813_184738`。TSDaemon `.171` pid 555 / `.149` pid 3274；`.171` SB pid 70。
- **P6 现包 PASS**（C98，不装包不杀 SB）：`.101` `P6_UICREATE_GATE_20260813_184558_101`；`.166` `…_184625_166`；`.112` `…_184654_112`。直接 dump 5/5；服务仍 AppWindow provider=8。汇总 `…_184558_101/REPORT.md`。
- **Toast+锁屏现包 PASS**（C98）：`.101` `TOAST_LOCK_GATE_20260813_190242_101`；`.112` `…_185531_112`；`.166` `…_185604_166`。App/Home/解锁后 Toast `visible_commit`；lock/unlock 均 ok；回 App 色 `12688231`。`/snapshot` 不含 Toast 窗，OCR `text_missing` 不作 FAIL。汇总 `…_190242_101/REPORT.md`。
- `.171`：`tmp_shots/TS_OBS/20260813_190331` TSDaemon 555 / SB 70。`.149` 本窗 SSH 闪断一次。
- **P7 同窗 COMPARISON_COMPLETE**（C98，不装包不杀 SB）：`tmp_shots/P7_SAMEWIN_C98_20260813_191541` + `tmp_shots/TS171_BIZ_READONLY_20260813_191541/summary.json`。6 轮：`.171` TSDaemon/SB/App PID 不变；`.101` Home 6/6、色 `12688231`、provider=8。不是触动内部 find 耗时，禁宣称超越。
- **P2 效率数字 PASS**（C98 现包，daemon color_req，24 样本）：`tmp_shots/P2_FIND_EFF_C98_20260813_192721`。三机 getColor/find 24/24 金标 `12688231` / 命中 `(706,449)`；find P95 `.101` 186 / `.112` 338 / `.166` 314 ms，均 ≤1200。`.112` getColor max=1280 一针，P95=1120 仍过线。不是触动内部 find。
- `.171` 本窗只读：`tmp_shots/TS_OBS/20260813_193000` TSDaemon 555 / SB 70 / App 76081。`.149` 本窗 SSH 未收回。
- **P8 同包总报告已出**：`tmp_shots/P8_TOTAL_REPORT_20260813_194639.md`，判定 `REPORT_COMPLETE_NOT_FINAL`。三机 dpkg 均为 C98。不是产品全绿，禁宣称超越。
- **Z1-TOUCH C98 三机 PASS**：桌面点码头 `(1080,320)` 打开游戏。`.101`/`.166` 前台+画面都变；`.112` Home 快照失败，只以前台 `springboard`→`com.xztl.ios` 判定。路由是 SB 中继（`ok=0` 按设计）。证据 `tmp_shots/Z1_TOUCH_C98_20260813/REPORT.md`。点后三机色 `12688231` AP=8。
- **Z1-MEM C98 5min 三机 PASS**：`tmp_shots/Z1_MEM_C98_20260813_195935`。会话 embed 找色加压，无 Desktop lua / pretest / `.53`。FC_N=1、SB_CHG=0、keep 停后清、workset 5.81MB、embed_find 220–389。短窗斜率不作 30min OLS。
- **Z1-MEM C98 debug-3 30min 三机 PASS**：汇总 `tmp_shots/Z1_MEM_C98_30M_20260814/REPORT.md`。硬门槛 SB_CHG=0 / FC_N=1 / keep 停后清 / workset 5.81MB / embed_find 1669·1080·1810 / color_req=0。OLS +3.0 / +3.2 / +0.9 KB/100s（≈0，不写成优于触动）。首刀脚本因 `.166` 开跑 SSH 拒写 FAIL，`.166` 同门禁重开 PASS。不是 Z2，未跑 `.53`。
- **Z1-ASSET color_req 同源自证三机 PASS**（keep+shm，禁 HTTP）：`.112` `tmp_shots/Z1_ASSET_SHM_PROVE_20260813_210301`（15.1s）；`.101`/`.166` `tmp_shots/Z1_ASSET_SHM_PROVE_20260813_212736`（2.15s / 0.67s）。三机均 `454,256` d=0，色 `12688231`，keep 停后清。
- **根因（不是匹配器）**：`keepScreen` 只锁文件 shm seq，**从未 `SetPinned(YES)`**。findImage 读 resident；Mac 裁 shm 的数秒里 AppWindow 仍 Renew。
- **keep-pin 已进 debug-2**：`KeepEnable` 后 `MirrorFromShm` + pin；关 keep / 切前台 / TTL 必 unpin。
- **Z1-ASSET 官方门禁三机 PASS**（keep+shm+color_req，禁 HTTP / 禁独立 ziyan_run）：`.112` `VISION_ASSET_20260813_214555`（17.9s）；`.166` `…_214721`（0.68s）；`.101` `…_214739`（2.76s）。均 `454,256` d=0。
- **独立 ziyan_run 找图回执三机 PASS（已进 debug-3）**：装包后复验 `Z1_ASSET_ZIYAN_RUN_20260814_004018`：`.112` 25s / `.101` 2s / `.166` 2s，均 `454,256` d=0。证据 `tmp_shots/Z1_ASSET_DEBUG3_20260814/REPORT.md`。不是匹配器。
- `.171`/`.149` 本窗只读：`tmp_shots/TS_OBS/20260813_220743`。TSDaemon `.171` 555 / `.149` 3274；`.171` SB 70；`.149` SB 70097。未部署。
- **`.166` 黑屏事件（22:01 报，22:06 一次 sbreload）**：物理 Home 无反应、锁屏键有反应。一次 `sbreload` 后远程 `.ziyan_go_home` 通（1000ms → springboard），金标仍 `12688231` AP=8。**不写成 keep-pin 产品 bug**。Z1-ASSET PASS 不被推翻。
- **`.166` 物理 Home（22:49 报死 → 23:01 你确认正常）**：钩子未装，不是 `singlePressUp` 吞事件。22:10 后已在桌面，按 Home 会像没反应；22:58 亮屏并拉回游戏后，你确认正常。**不重开 Home 钩子**。不是 keep-pin 产品 bug。
- **P2 C98 三机**：效率 PASS + Gate C 30m 30/30 PASS。无 `.53`。禁宣称超越。
- **Z1-VIS C98 现窗未齐**：`.101` BUSINESS_PASS；`.112` VISION_MISS（`ios7.lua` `1010,294`）；`.166` 已找到并点进游戏，官方因 A1 回执 FAIL。`.53` 未重跑。证据 `tmp_shots/Z1_VIS_C98_20260814/REPORT.md`。
- **P0 Day1 仪表盘已采**（无产品改动）：`tmp_shots/P0_DASHBOARD_20260814_023009`。游戏前台三机 provider=8、front=shm、金标 `12688231`、FC_N=1、age<2s。Idle Home `seq=0 age=-1`（释帧，当时缺具名 lease_state）。
- **P0 Day2 lease_state 已上三机**：`tmp_shots/P0_DAY2_LEASE_20260814_064945`。
- **P0 Day3 find 诊断已上三机**：`tmp_shots/P0_DAY3_FIND_20260814_082032`。
- **P0 Day4 find 只读 resident 已上三机**：`tmp_shots/P0_DAY4_RESIDENT_20260814_083551`。无 resident 回 `reacquiring` ~7–10ms；有 resident 三机 embed 金标 `12688231`、find `(701,447)`、`source=resident` wall 0.8–2.9ms、`via_color_req_find=0`。**不是 P0 全绿**（Day5 才 10 分钟定位窗）。`.53` 未部署。
- **P0 Day5 10min 定位窗已采**（无产品改动，debug-6）：`tmp_shots/P0_DAY5_LOCATE10_20260814_094034`。三机 hit 541/543、406/407、630/636；诚实分类 none_systemic。**不是 P0 全绿**。
- **P0 Day6 短业务回归三机 PASS**（无产品改动，debug-6）：`tmp_shots/P0_DAY6_BIZREG_20260814_100215`。live/keep/back 三机金标 `12688231` find `(701,447)`；keep 期 last_find `keep=1`；Home 三机 springboard `pixel_miss` 非冻帧；KEEP_AFTER=0；SB_CHG=0；FC_N=1；`via_color_req_find=0`。首版 CLASS `KEEP_NOT_ON` 是脚本结束后取样 keep 文件，已按 last_find 纠正。**不是 P0 全绿**（Day7 才第一周完成条件复核）。`.53` 未部署。
- **P0 Day7 第一周完成条件三机复核 PASS**（无产品改动，debug-6）：`tmp_shots/P0_DAY7_WEEK1_20260814_103827`。5min 金标窗：relay/UICreate/black 窗内 0；seq 推进；age p95 871/958/779ms；hit 271/274、207/208、321/321；color_req=0；SB_CHG=0；FC_N=1。自动 AGE_SUSTAINED 含开跑 reacquiring 高龄，诚实只计 active 连续≥2s：`.101` 0 / `.112` 1 / `.166` 2。WATCH：开跑 4–8s seq 停。无 `.53`，**不是四机周完成、不是产品全绿**。
- `.53` 已恢复进验收集，尚未部署；BBFrame OFF。

## 1. 为什么此前反复卡住

1. 长期修补 IOMFB、UICreate、CARender、BBFrame、SpringBoard relay，但这些系统级路径在目标游戏前台不能稳定取得正确内容。
2. 旧门禁过度相信 seq、帧龄、HTTP 200和PNG存在，没有强制验证画面内容和脚本标准色。
3. 单次真值、3轮、10轮未通过前就过早进入30/50分钟长测，重复产生同类失败。
4. 曾混用无签名中间产物与最终签名产物，导致退出码137/Jetsam；设备版本尾号也不一致。
5. 自动测试没有完整模拟人工 Home、锁屏/解锁、真实前台确认和 Toast 视觉位置。
6. Toast方向状态机与截帧问题混在一起，没有单独闭环。

## 2. 已证实的事实

### 2.1 已淘汰为游戏前台主帧源的路径

| 路径 | `.101` 实测结论 | 是否可作为游戏前台正确帧源 |
|---|---|---|
| daemon UICreate | 接近全黑 | 否 |
| CARender | 接近全黑 | 否 |
| `UIWindow createScreenIOSurface` | 压缩伪色 | 否 |
| IOMFB layer0 | 低亮、固定或伪画面 | 否 |
| IOMFB layer1–7 | nil | 否 |
| BBFrame | 请求未被消费，Home/App同一旧帧 | 否 |
| SpringBoard relay | Home正确；App `write_black` | App前台否 |

证据：

- `tmp_shots/IOMFB_DIAG_20260811_071454_101`
- `tmp_shots/BBFRAME_MATRIX_20260811_071657_101`
- `tmp_shots/SBRELAY_MATRIX_20260811_071946_101`

禁止事项：不得继续仅通过调节这些路径的超时、预算或重试次数来宣称解决游戏前台黑帧。

### 2.2 已找到的正确 App 帧源

- 注入目标：`com.xztl.ios` / `FGCQLibClient-mobile`。
- 来源：目标 App 主线程对可见 `UIWindow` 调用 `drawViewHierarchyInRect:afterScreenUpdates:NO`。
- 逻辑输出：`1136×640` RGBA8888。
- 新 provider：`ZiYanFrameProviderAppWindow=8`。
- UIKit绘制留主线程；RGBA转换和共享内存提交放串行后台队列。
- 显式请求、单飞；App非Active、窗口不可用时拒绝，不覆盖最后健康帧。

`.101` 真值结果：

| 项目 | 结果 |
|---|---|
| 标准点 `(706,449)` | `0xc19b67`，与 `ios7.lua` 一致 |
| 修正后首次耗时 | 27.9ms |
| 连续10次 | 10/10成功 |
| 连续10次耗时 | 36.6–56.5ms |
| seq | 15→24连续推进 |
| 游戏PID | 10573，全程不变 |
| framecap PID | 48501，全程不变 |
| SpringBoard PID | 48520，全程不变 |
| 游戏RSS | 118288KB→118320KB（约+32KB） |

2026-08-11真实业务接入新增证据：

- 文件队列getColor 10/10均为`0xc19b67`，provider=8，AppWindow 30.9–52.8ms。
- 内嵌业务21个慢样本：P50=159.8ms、P95=214.1ms、max=215.3ms。
- Home resign-active立即stale；3轮回App标准色3/3正确。
- Home正确桌面帧恢复为500/1050/100ms；第三轮回App报告输出被中止，故整体仍为PARTIAL_PASS。
- 随后Home/App 10轮为8/10：第5轮Home恢复超过1200ms；第6轮回App请求撞新epoch后超时/stale。10轮仍FAIL，未进入30分钟。
- C57修复上述两点后，`.101`重新执行Home/App 10轮为10/10：Home恢复全部≤1150ms，回App标准色10/10为`0xc19b67`，Home provider=7/Valid、App provider=8/Valid，三大PID稳定。
- `.101` P2 30分钟已于2026-08-11 09:26:54启动，每分钟真实Home；`.171`同步只读系统Home对照。前2分钟均PASS，完整30分钟尚在运行，未完成前P2仍为IN_PROGRESS。
- 上述窗口在第15分钟受对话工具中断；前14分钟全PASS，但禁止拼接为30分钟。2026-08-11 09:56:01已用macOS launchctl独立作业从0重启连续30分钟，不再依赖当前对话会话；第1分钟PASS。
- 证据：`tmp_shots/ITERATION_20260811_0812_101/REPORT.md`。

证据：`tmp_shots/APPFRAME_PROVIDER_20260811_0734_101/`。

注意：第一版RGBA转换发生上下颠倒，标准点为 `0x31241b`，已经修正。此失败明确说明“provider成功、seq推进”仍不等于画面真值通过。

### 2.3 C76→C79 Home生命周期收敛

- C76 round 1证据：`HOME_OK=0`/`HOME_MS=1254`/provider 8 stale；主Home动作未生效，650ms fallback才使App resign，而旧ACK窗口只到380ms。
- C78尝试改为完整硬件Home Down→Up主动作和一次fallback，但部署前审计发现其ACK/terminal所有权不能严格绑定一次事务，存在旧证据参与提交及App回弹与Home提交双赢的风险；C78包保留为历史证据，判定为`REJECTED_BEFORE_DEPLOY`。
- C79使用协议v3、跨进程`mach_continuous_time()`、per-nonce resign/background/cancel/terminal/commit-evidence文件；App Active先保留cancel再原子争抢terminal，SpringBoard只有在background ACK、精确原生Home、明确未锁屏、deadline和terminal全部满足时才提交canonical前台。
- C79将SpringBoard设为`.ziyan_front_bid`唯一写者，并修复周期同BID样本提前清空1200/1500ms reducer guard的竞态；严格runner在确认Home后执行独立4.5秒稳定窗并锁存cancel/rebound。
- C79 deb：`packages/com.ziyan.ziyan_0.0.92-8-161-205-C-65.11-79+debug_iphoneos-arm.deb`。
- C79 deb SHA256：`7d4ff7333c7185d82fbb9ad3640a0c58a5f826505af28142d765400cec3ca42c`。
- 包内 `ZiYanVol.dylib` SHA256：`7fc98e29020a0b0301043d39afa097874be85c357dd6d1f0699ab1169bff52fd`；包内 `ZiYanAppTouch.dylib` SHA256：`ac093496b6c54a1752a29859f1d833e1a9970c297abfeb68a2030f5ebcdc4ac2`；包内framecap SHA256：`9fb369406c3923fb9e2354b1522d88eb0dbaddd2ff807e5a67005e7ee57fbf00`。
- 包内 `cv.lua` SHA256：`aa4867e0a4f88f665d9ca0c58fe58b39854f5e4888240b7bf0b13243ea468215`；`ziyan_chumo_screen.lua` SHA256：`91b97d88e5682948bc37898118eb3cb5d5b962d78cce39cba4863ea23766c8ed`。
- strict runner SHA256：`49f49a5bbf2222b49cbc84d8b30c0e76c9ef4d5095792db29db719c002adf065`；`EXPECTED_DEB_SHA`已回填，设备最终重签framecap SHA仍待`.101`部署后回填。
- `ZiYanVol.dylib` 含C79 v3/per-nonce/commit证据标记，不含C77的 `SBFrontmostApplicationDisplayIdentifier`/`SBSCopy...`。旧引擎 `wnriakwyww` 仍有历史 `SBFrontmostApplicationDisplayIdentifier`，不得宣称“整包零残留”。

## 3. 当前源码和设备状态

### 3.1 当前相关源码

- `objc/tweak/apptouch/ZiYanAppTouch.m`：App帧显式请求、单飞、后台RGBA提交，以及C79 v3生命周期ACK/cancel/terminal发布；仍保留按请求才执行的旧诊断入口，正式收口时应删除或编译期开关。
- `objc/shared/ZiYanFrameShm.h`：追加 provider=8。
- `Makefile`：AppTouch编入 `ZiYanFrameShm.m`，增加CoreGraphics。
- `tools/ziyan_framecap/main.m`：provider=8已接入真实找色热路径；历史IOMFB/UICreate/relay路径仅能作受控fallback/诊断，不得在App provider在途时并发风暴。
- `tools/ziyan_framecap/ZiYanLuaEmbed.m`：禁止强弃旧Lua线程后开第二VM；find/getColor均先释放resident读票和`gShmMu`再写诊断；每次业务VM发布单调`vm_gen/vm_start_mono_ms`。
- `lua/ziyan_engine/cv.lua`：业务VM API CSV使用embed单调钟、8MiB窗、连续seq与VM代际；cold路径隔离；native唯一写pulse/perf。
- `lua/ziyan_chumo_screen.lua`：重复安装幂等，冻结真正原生入口，避免二次包装递归后静默返回-1。

### 3.2 设备状态

| 设备 | 当前状态 | 约束 |
|---|---|---|
| `.101` | **C-65.11-93** 包 + **C94 ziyan_ocr** 热更（未杀 SB）；30m **PASS**；P3 FAIL | BBFrame OFF |
| `.112` | **C-65.11-93** 包 + **C94 ziyan_ocr** 热更；30m **PASS**；P3 FAIL | BBFrame OFF |
| `.166` | **C-65.11-93** 包 + **C94 ziyan_ocr** 热更；30m **PASS**；P3 FAIL | BBFrame OFF |
| `.53` | debug-10-24-4 已装；RUN1 BUSINESS_PASS | rootless + ios8p.lua；TweakInject 已链 Vol；BBFrame OFF |
| `.171` | 触动精灵只读基准 | 禁部署、修改、重启 |

`.101` 回滚文件：

- `/var/mobile/Media/ZiYan/rollback/ZiYanAppTouch.pre_diag_20260811_072321.dylib`
- `/var/mobile/Media/ZiYan/rollback/ZiYanAppTouch.pre_appframe_20260811_0732.dylib`
- `/var/mobile/Media/ZiYan/rollback/pre_0.0.92-8-161-205-C-65.11-76_debug_20260812_002236`（设备时钟记录；当前SSH失联时尚无法重验）

如果原型失败或任务中断，应恢复上述适当备份并只重开目标App；不需要重启SpringBoard。

## 4. 当前唯一实施顺序

### Gate A：接入真实找色热路径

目标App前台时：

1. framecap确认真实前台bundle和目标App进程存在。
2. 需要新帧时写 `.ziyan_app_frame_req`，包含唯一nonce。
3. AppTouch异步单飞取得正确窗口帧并提交provider=8。
4. framecap只接受 `provider=8 + status=Valid + front_hash匹配 + seq推进` 的当前epoch帧。
5. 找色读取新健康帧；超时明确FAIL，禁止退回Home旧帧或黑帧冒充成功。
6. App provider在途时禁止并发启动无效的UICreate/relay风暴。
7. 常驻resident槽必须能看到其他进程提交的新seq，不能继续扫描旧槽。

### Gate B：Home/App epoch

- Home：立即废止App lease，取得并验证正确Home画面。
- 回App：立即废止Home lease，等待provider=8及目标front hash。
- bid文件、真实进程、SpringBoard真实前台和图像内容必须同时一致。

### Gate C：逐级测试

1. ~~恢复 `.101` SSH~~（2026-08-12 16:57）。
2. ~~部署可注入包到 `.101`~~（C79→发现 AppTouch plist 损坏→C86→**C87**；Filter OK + ios13 Home）。
3. ~~`.101` 单轮 Home/App/找色/Toast~~（FUNCTIONAL_PASS）。
4. ~~正式 10 轮~~（2026-08-12 17:57 **10/10 PASS**，证据 `ITERATION_20260812_175408_C87_10R_101`）。
5. ~~`.101` 30 分钟~~（2026-08-12 19:18 **VERDICT=PASS**，`P2_30M_C88_20260812_184759_101`）。
6. ~~扩展`.112/.166`~~（`.112` C88 30m PASS；`.166` C90 10R PASS + 30m 跑中）。
7. **下一步**：等 `.166` 30m SUMMARY；三台全绿后才宣称 Gate C 完成。
8. P2全绿后继续P3、P5、P6、P7、P8。

## 5. P2不可降低的门禁

- 首轮不得seq=0。
- stale、front mismatch、旧epoch命中均为0。
- App/Home图片必须不同且内容正确。
- 脚本标准色正确率100%，不能只检查“有返回值”。
- find P50/P95、最大值和前台恢复时间必须记录；P95≤1200ms。
- Home键有响应；无卡屏、黑屏、假活。
- SpringBoard、backboardd、App不得异常重启。
- framecap单实例。
- RSS无持续增长，停止后无脚本/帧任务残留。
- Toast始终服从脚本`init`方向，Home瞬间和锁屏/解锁后不得错位。
- 与`.171`采用同一时间窗和口径；未完成对照不得宣称超越。

## 6. 后续阶段当前真实判定

| 阶段 | 当前判定 | 原因 |
|---|---|---|
| P2 | 三机 PASS（C98） | 效率 C98 PASS + Gate C 30m C98 30/30。无 `.53`。禁宣称超越触动。不是四机全绿 |
| P3 | PASS | C96 金标 45/45；zh=`子砚测试` via tess3:chi_sim；证据 `tmp_shots/OCR_GOLD_RUN_20260813_C96` |
| P5 | FAIL | C96 3h 未齐；C98 仅 10/10。用户 2026-08-13 决定不再开 180m，3h 未用 C98 收口 |
| P6 | PASS | C98 现包三机：直接 uicreate-dump 5/5、无 child 崩、AppWindow 仍 provider=8；证据 `P6_UICREATE_GATE_20260813_184558_101/REPORT.md` |
| P7 | COMPARISON_COMPLETE | C98 与 `.171`/`.149` 同窗 6 轮；进程稳态 + `.101` Home/标准色；非内部 find 耗时；禁宣称超越 |
| P8 | REPORT_COMPLETE_NOT_FINAL | C98 汇总已出 `P8_TOTAL_REPORT_20260813_194639.md`；P2 三机已齐但无 `.53`，P5 3h 仍 FAIL，故不是最终 PASS |

旧 `tmp_shots/P8_TOTAL_REPORT_20260810_193557.md` 中的P2 PASS只验证旧门禁的帧龄/元数据，不足以证明画面正确，自本账本建立起不得引用为当前P2 PASS。

## 7. 禁止重复的错误

- 禁止把低帧龄黑帧、伪色帧、旧帧写成PASS。
- 禁止把HTTP 200短正文当PNG。
- 禁止把OCR非空返回写成识别准确。
- 禁止在单次/3轮/10轮未绿时启动30/50分钟长测。
- 禁止混用 `.theos/obj/debug/arm64/ziyan_framecap` 无签名中间文件；只可使用最终签名产物。
- 禁止失败包留设备；失败必须恢复已核验备份。
- 禁止`.101`未绿就部署`.112/.166`。
- 禁止触碰`.53/.171`的约束边界。
- 禁止发现ZiYan异常后继续盲调；必须固化现场并按同阶段比较`.171`，必要时补充`.149`只读证据。

## 8. 每轮更新要求

每轮必须追加到 `DOCS/TEST_ITERATION_TEMPLATE.md` 的副本或在本文件末尾新增记录，至少包含：假设、改动、构建产物SHA、部署目标、备份、PID前后、画面真值、标准色、P50/P95、RSS/CPU、Home/锁屏/Toast结果、`.171`同窗结果、PASS/FAIL、失败根因和下一条唯一动作。

## 9. 2026-08-13 P7 同窗

- 假设：C98 现包可与触动同窗对照进程稳态与 Home/标准色，不测触动内部 find。
- 改动：仅新增 `tools/zy_p7_samewin_gate.sh`；不装包、不杀 SB、不写 `.149`/`.171`。
- SHA：`5c956619c26726e13635d804a3c085afce16d8dcd9bef7d7e57c1316dc1479c9`
- 部署：无（现包）
- PID：`.171` 555/70/76081 全程；`.101` 75884/75864/88640 全程
- 标准色：`.101` 6/6 = `12688231` AP=8
- P50/P95：本窗未采（秒级 Home_ms，不作 find 效率）
- RSS/CPU：见 `COMPARE.md`；`.166` `ps` 对 SB/App 报 RSS=0 为该机 quirk
- Home：`.101` 6/6；`.171` activator Home 6/6 完成
- 判定：`COMPARISON_COMPLETE`（不是超越）
- 下一条唯一动作：P2 效率数字（find P50/P95 ≤1200ms）

## 10. 2026-08-13 P2 效率

- 假设：C98 现包 daemon getColor/findMulti 可在 24 样本内交出 P50/P95，P95≤1200，色必须金标。
- 改动：仅新增 `tools/zy_p2_find_eff_gate.sh`；不装包、不杀 SB、不启 Desktop lua。
- SHA：`5c956619c26726e13635d804a3c085afce16d8dcd9bef7d7e57c1316dc1479c9`
- 部署：无（现包）
- PID：`.101` 75884/75864/88640；`.112` 17527/17692/76457；`.166` 1862/1852/12052 全程未换
- 标准色：三机 24/24 = `12688231` AP=8；find 命中 `(706,449)`；负例 4/4 miss
- P50/P95：find `.101` 87/186、`.112` 119/338、`.166` 82/314；get `.101` 330/571、`.112` 190/1120、`.166` 85/322
- RSS/CPU：短窗无 PID 换；`.166` `ps` RSS=0 quirk 仍在
- Home/锁屏/Toast：本刀未测
- `.171`：TSDaemon 555 / SB 70 / App 76081；`.149` SSH 限流未收回
- 判定：效率三机 PASS（不是超越；P2 总判定仍 IN_PROGRESS，因 Gate C 30m 未在 C98 重跑）
- 下一条唯一动作：P8 同包总报告，或等用户指定 Z1-TOUCH/Z1-MEM / `.53`

## 11. 2026-08-13 P8 同包总报告

- 假设：把 C98 已收证据收成一份总报告，不把生成报告写成产品 PASS。
- 改动：重写 `tools/zy_p8_report.sh`，收录效率/OCR/P5/P6/Toast/P7/版本/触动只读。
- SHA：`5c956619c26726e13635d804a3c085afce16d8dcd9bef7d7e57c1316dc1479c9`
- 部署：无。三机 dpkg 均为 C98。
- 证据：`tmp_shots/P8_TOTAL_REPORT_20260813_194639.md`；触动 `tmp_shots/TS_OBS/20260813_194639`（`.171` 555/70/76081，`.149` 3274/70097）
- 判定：`REPORT_COMPLETE_NOT_FINAL`
- 下一条唯一动作：等用户指定 Z1-TOUCH / Z1-MEM，或解禁 `.53`。不开 180m，不宣称超越。

## 12. 2026-08-13 Z1-TOUCH

- 假设：C98 现包从桌面点码头游戏图标，HID/中继能落地并换前台。
- 改动：不改产品代码；`.112` 快照失败时只以前台判定。
- SHA：`5c956619c26726e13635d804a3c085afce16d8dcd9bef7d7e57c1316dc1479c9`
- 部署：无
- 标准色：点后三机 `12688231` AP=8
- 判定：三机 PASS（SB 中继落地，不是原生 BKHID）
- 下一条唯一动作：Z1-MEM 短窗，但不得用官方 `zy_e4_promo_gate.sh` 原样（它会 pretest_clean / 启 Desktop lua / 碰 `.53`）

## 13. 2026-08-13 Z1-MEM 5min

- 假设：C98 现包用会话 embed 找色加压 5min，可验单宿主/停后释放/workset，不启 Desktop lua。
- 改动：仅新增 `tools/zy_z1_mem_c98_gate.sh`。
- SHA：`5c956619c26726e13635d804a3c085afce16d8dcd9bef7d7e57c1316dc1479c9`
- 部署：无
- PID：三机 framecap/SB 全程未换
- RSS：`.101` +5 KB/100s；`.112`/`.166` 回落。短窗不作 OLS
- 判定：三机 PASS（不是 30min / 不是超越）
- 下一条唯一动作：等用户指定。候选 Z1-VIS（禁改 Desktop 色点）、Z1-ASSET、或解禁 `.53`。不开 180m。

## 14. 2026-08-13 Z1-ASSET

- 假设：从当前游戏帧裁块再搜回去，可证 findImage。
- 改动：不改产品代码；`.112` 第二次改走 embed，仍无坐标。
- SHA：`5c956619c26726e13635d804a3c085afce16d8dcd9bef7d7e57c1316dc1479c9`
- 部署：无
- 判定：2/3 FAIL（`.112` 回执/条带）
- 下一条唯一动作：`.112` 找图回执，先对照 `.171`，禁止第三轮盲改。不开 180m，不改 Desktop 色点。

## 15. 2026-08-13 .112 找图回执

- 假设：回执空是等待口径，不是找图算法全坏。
- 触动：同进程返回；子砚独立 lua 走文件 IPC，8s `os.clock` 对不上 `.112` 11.5s 守护。
- 改动：`wait_rep_wall` 20s；门禁去掉 getText。scp `cv.lua`，未打新包。
- 判定：回执路径已修；Z1-ASSET `.112` HTTP 自证仍 FAIL。
- 下一条唯一动作：等用户指定。不要再盲改匹配算法。不开 180m。

## 16. 2026-08-13 .166 黑屏恢复

- 假设：SSH 活 + 锁屏键有反应 + 金标仍在 = 合成器假活/灭屏，不是死机；一次 sbreload 可恢复 Home。
- 改动：无产品代码、无新 deb。只做一次 `sbreload`，不杀 backboardd，不热换 framecap。
- SHA：仍 `a42cf3c83e8dba1e0e3bc684bf1b9c6aa2531be2595e70e096718f2a48535194`（debug-2）。
- 部署：无。
- PID 前：framecap 36802 / backboardd 36809 / SB 36810（etime≈45m，对齐 21:21 装包）。
- PID 后：framecap 36802 / backboardd 64571 / SB 64572。游戏重开 65289。
- 画面真值：sbreload 前金标 `12688231` AP=8；sbreload 后 shm 一度 0 字节（`app_not_active_evidence`）；uiopen + active evidence 后 shm 2.9MB、ack ok、金标 `12688231` AP=8。
- Home：远程 `.ziyan_go_home` → `HOME_OK=1` / 1000ms / `com.apple.springboard`。物理 Home 请你本地确认。
- 锁屏/Toast：本窗未再跑门禁。
- `.171`/`.149`：`tmp_shots/TS_OBS/20260813_220743`（555/70；3274/70097）。
- 判定：设备事件已恢复。**不是** keep-pin 根因结论。Z1-ASSET PASS 仍有效。
- 下一条唯一动作：见 §17（sbreload 后物理 Home 仍报死）。

## 17. 2026-08-13 .166 物理 Home 仍死（钩子未吞）

- 假设：sbreload 后物理 Home 仍死，应查 `ZiYanHookHomeButton` / `singlePressUp` 是否吞事件。
- 触动对照：`tmp_shots/TS_OBS/20260813_225920`（`.171` 555/70；`.149` 3274/70097）。
- 证据：`.ziyan_hooks` = `volume_menu+toast+icon`，`zero_sb_full=1` `sb_vol_thin=1`。物理 Home 钩子按设计未装（避免 iOS 13 Home action 重入卡死 `.166`）。`.101` 同配置。远程 `.ziyan_go_home` 通。
- 改动：不改产品代码、不重开 Home 钩子、不重装包。22:58 短会话 unlock 亮屏后立刻清会话；拉回游戏 `com.xztl.ios`。
- 标准色：`12688231` AP=8。
- 判定：23:01 **你确认已正常**。不是 `singlePressUp` 吞事件。当时已在桌面 + 灭屏，按 Home 会像没反应；亮屏并拉回游戏后物理 Home 正常。
- 下一条唯一动作：见 §18。

## 18. 2026-08-13 独立 ziyan_run 找图回执

- 假设：独立 lua 假 miss 是墙钟等待/转义，不是匹配器。
- 改动：`lua/ziyan_engine/cv.lua` `wait_rep_wall` 用 `/bin/sleep 0.05` + JSON 兜底 + `string.char(10)`；门禁 `tools/zy_z1_asset_ziyan_run_gate.sh`。不改匹配器，不装新 deb，不杀 SB。
- 部署：三机热补 `cv.lua`（有 `.pre_waitfix`）。
- 标准色：三机 `12688231`；命中 `454,256` d=0。
- `.171`/`.149`：`tmp_shots/TS_OBS/20260813_232505`（555/70；3274/70097）。
- 判定：三机 PASS。热补当时未进 deb；见 §19。
- 下一条唯一动作：见 §19。

## 19. 2026-08-14 debug-3 进包复验

- 假设：把已过的 `wait_rep_wall` 打进 deb 后，独立 `ziyan_run` 仍能打到 `454,256`。
- 改动：`control` / `layout/DEBIAN/control` 版本 `+debug-3`；`cv.lua` 已在树内。不改匹配器，不重开 Home 钩子。
- SHA：`7cba2d7128c388282eef9be6b5641e9612877fbf33337112484be1972849ea35`
- 部署：`.101` / `.112` / `.166`。未部署 `.53` / `.149` / `.171`。
- 标准色：三机 `12688231` AP=8；命中 `454,256` d=0。
- `.171`/`.149`：装包前 `tmp_shots/TS_OBS/20260814_003326`（555/70；3274/70097）。复验窗 `.171` SSH 闪断一次，补采 TSDaemon 555 / SB 70。
- 判定：debug-3 三机 PASS。不是超越。
- 下一条唯一动作：见 §20。

## 20. 2026-08-14 Z1-MEM 30min

- 假设：debug-3 现包、显式 keep、embed 找色加压 30min，硬门槛与 OLS 不劣于触动长窗。
- 改动：门禁补 TSV 回传 + `zy_rss_slope_analyze.py` OLS。不改产品代码、不装新 deb、不杀 SB。
- SHA：仍 `7cba2d7128c388282eef9be6b5641e9612877fbf33337112484be1972849ea35`（debug-3）。
- 部署：无。只跑 `.101` / `.112` / `.166`。
- 证据：`.101`/`.112` `tmp_shots/Z1_MEM_C98_20260814_004939`；`.166` `tmp_shots/Z1_MEM_C98_20260814_005252`（开跑 SSH 拒后重开）；汇总 `tmp_shots/Z1_MEM_C98_30M_20260814/REPORT.md`。
- 硬门槛：三机 PASS。SB/FC PID 未换；embed_find 1669/1080/1810；color_req=0；keep 停后清；workset 5816320。
- OLS：+3.0 / +3.2 / +0.9 KB/100s。`.112` 短窗 PER100=−165 是锯齿，OLS 仍 ≈0。
- `.171`/`.149`：本窗 start/end 在上述 OUT 的 `ts171_*.txt` / `ts149_*.txt`。TSDaemon `.171` 555 RSS 34352 持平 / SB 70；`.149` 3274 / SB 70097。
- 判定：Z1-MEM 30min 三机 PASS。**不是 Z2**（无 `.53`、无官方 e4 四机）。禁宣称超越。
- 下一条唯一动作：见 §21。

## 21. 2026-08-14 C98 Gate C 30m

- 假设：debug-3 现包每分钟真 Home → 回游戏 → 金标 `12688231` / provider=8，30 轮 PID 不换。
- 改动：新门禁 `tools/zy_p2_c98_30m_gate.sh`（C93 口径，参数化三机）。不改产品代码、不装新 deb、不杀 SB。不向 `.171` 发 Home。
- SHA：仍 `7cba2d7128c388282eef9be6b5641e9612877fbf33337112484be1972849ea35`（debug-3）。
- 部署：无。只跑 `.101` / `.112` / `.166`。
- 证据：`tmp_shots/P2_30M_C98_20260814_013438`。三机 30/30，末轮色 `12688231` AP=8。无 PASS=0 / SSH_FAIL / FCN=2。
- PID：`.101` FC 73337 / SB 73357 / BB 73344；`.112` FC 57994 / SB 57811；`.166` FC 87040 / SB 87053。整窗未换。
- Home：HOK=1 HOME_MS=1000；桌面 provider≠8。回 App APP_RETRY 约 4。
- `.171`/`.149`：本窗 `ts171_start/end.txt` `ts149_start/end.txt`。TSDaemon `.171` 555 / SB 70；`.149` 3274 / SB 70097。只读，未发 Home。
- 判定：Gate C 30m C98 三机 PASS。P2 三机（效率+Gate C）已齐。**不是 Z2**，无 `.53`，P5 3h 仍 FAIL。禁宣称超越。
- 下一条唯一动作：见 §22。

## 22. 2026-08-14 Z1-VIS 三机

- 假设：不改 Desktop `ios7.lua`，只 scp 跑官方 RUN1，看 debug-3 能否 `TYPED=BUSINESS_PASS`。
- 改动：无产品代码、无新 deb。门禁 `zy_run1_script_logic_gate.sh` 分跑 101/112/166。不碰 `.53`。
- SHA：仍 `7cba2d7128c388282eef9be6b5641e9612877fbf33337112484be1972849ea35`。ios7 SHA `0a6325ca9a091a864a6c8e6e226be2dc952e39890c833702652b51a09ea55d3c`。
- 证据：`tmp_shots/Z1_VIS_C98_20260814/REPORT.md`。
- `.101`：BUSINESS_PASS。tap `1010,294` → `com.xztl.ios`。
- `.112`：VISION_MISS。主搜 `1010,294` miss，落到登录 ROI `25,21`。请你改 Desktop 色点；助手不改。
- `.166`：找到并点进游戏，官方因 A1 embed 3s 回执否决写成 FAIL。不把官方改写成 PASS。
- `.171`：`tmp_shots/TS_OBS/20260814_021130` + 02:18 补采 555/70。`.149` 开始窗 3274/70097。
- 判定：Z1-VIS 未齐。禁宣称超越。
- 下一条唯一动作：见 §23。

## 23. 2026-08-14 P0 Day1 帧仪表盘

- 假设：现包已有 seq/age/provider/front/shm/lock_wait；缺具名 lease_state。先采再改。
- 改动：新只读门禁 `tools/zy_p0_frame_dashboard.sh`。不改产品代码、不装包、不杀 SB。
- SHA：仍 `7cba2d7128c388282eef9be6b5641e9612877fbf33337112484be1972849ea35`。
- 证据：`tmp_shots/P0_DASHBOARD_20260814_023009`。
- Idle Home：三机 session=idle、front=shm=springboard、seq=0/age=-1/provider=0、KEEP=0、FC_N=1。
- App：三机 provider=8、金标 `12688231`、front=shm=com.xztl.ios、age 704–1831ms、FC_N=1。
- `.171`/`.149`：本窗 `ts171.txt`/`ts149.txt`。555/70；3274/70097。
- 判定：Day1 采集完成。**不是 P0 全绿**。Day2 才给 lease 具名状态（先双写 /status，不改 find 热路径）。
- 下一条唯一动作：见 §24。

## 24. 2026-08-14 P0 Day2 lease_state 双写

- 假设：派生 `lease_state` 双写 `/status` + `.ziyan_lease_state`。不改 find/embed 热路径。
- 改动：`tools/ziyan_framecap/ZiYanSnapshotHttp.m` `SnapLeaseState`；仪表盘读 `lease_state`/`LEASE_FILE`。版本 `debug-4`。
- SHA：`9883d67844f666a0273a92f95c0a224740b3cf21eec2e53dd90ca9692ab8e4fe`。
- 证据：`tmp_shots/P0_DAY2_LEASE_20260814_064945`。
- 空 shm：三机 `lease_state=suspended`，KEEP=0，FC_N=1；`/status` 与文件一致。
- App：三机 `active` / provider=8 / 金标 `12688231` / front=shm=`com.xztl.ios`。
- 刚回桌面有桌面帧：三机 front=shm=springboard，lease=`active`（对齐有像素；不是游戏冻帧）。
- `.171`/`.149`：本窗 `ts171.txt`/`ts149.txt`。555/70；3274/70097。
- 判定：Day2 双写完成。**不是 P0 全绿**。Day3 才让 find 在 reacquiring 回诊断。
- 下一条唯一动作：见 §25。

## 25. 2026-08-14 P0 Day3 find 诊断回执

- 假设：lease 非 active 时 find 立刻回诊断，不扫、不堵 300ms Ensure。匹配器不动。
- 改动：`ZiYanFrameLeaseState` 进 `ZiYanFrameKeep`；`EmbedLeaseRefuseScan`；`/status` 共用。版本 `debug-5`。
- SHA：`45c8e231e24ad180a2a5654b4ff2bd6d97f974550d1a0463d992fbbd37f1f77c`。
- 证据：`tmp_shots/P0_DAY3_FIND_20260814_082032`。
- active：三机 embed 金标 `12688231`、find `(701,447)`、`via_color_req_find=0`、FC_N=1。
- 锁屏旗：`/status=suspended`；脚本热且非桌面时 find `class=reacquiring` / -1,-1 / 7–10ms；解锁后金标仍对。
- `.171`/`.149`：本窗 `ts171.txt`/`ts149.txt`。555/70；3274/70097。
- 判定：Day3 完成。**不是 P0 全绿**。Day4 才收紧 find 只读新鲜 resident。
- 下一条唯一动作：见 §26。

## 26. 2026-08-14 P0 Day4 find 只读 resident

- 假设：去掉 find/getColor 同步 `AppFrameEnsure`；无 resident 回诊断并异步催帧。不改匹配器、不改 ServeLoop。
- 改动：`ZiYanLuaEmbed.m`。版本 `debug-6`。
- SHA：`6bb1a90891384a0eab53aeff1a6c4a0030ba2b105430d36f96cdcdd0002bf6b4`。
- 证据：`tmp_shots/P0_DAY4_RESIDENT_20260814_083551`（空帧窗 `083308` + 命中补采 `hit_*.txt`）。
- 空帧：三机 `reacquiring` / 6–10ms。命中：三机金标 `12688231`、find `(701,447)`、`source=resident`、wall 0.8–2.9ms、`via_color_req_find=0`、FC_N=1。
- `.166` 部署 SSH 闪断一次，补装成功。
- `.171`/`.149`：555/70；3274/70097。
- 判定：Day4 完成。**不是 P0 全绿**。Day5 才 10 分钟定位窗。
- 下一条唯一动作：见 §27。

## 27. 2026-08-14 P0 Day5 10 分钟定位窗

- 假设：只测量，不改产品。四类分流：帧老化 / 锁等待 / 匹配耗时 / 前台错位。
- 包：仍 `C-65.11-98+debug-6-1+debug`。不装包、不杀 SB、不碰 `.53`。
- 证据：`tmp_shots/P0_DAY5_LOCATE10_20260814_094034`。
- 脚本：`tools/zy_p0_day5_locate10.sh`；embed `_p0d5_locate.lua` 400ms 间隔金标找色 600s。
- 三机：`.101` 543/541；`.112` 407/406；`.166` 636/630。lease 几乎全程 active，provider=8。
- 自动 CLASS：`.101`/`.112` LOCK,MATCH（慢日志 p95）；`.166` none。
- 诚实 CLASS：none_systemic。慢针 `.101` 4、`.112` 5、`.166` 0。不拧匹配器。
- `.171`/`.149`：555/70；3274/70097。起止 PID 未变。
- 判定：Day5 完成。**不是 P0 全绿**。Day6 才短业务回归。
- 下一条唯一动作：见 §28。

## 28. 2026-08-14 P0 Day6 短业务回归

- 假设：debug-6 上走真实短路径（金标 / 显式 keep / Home 不扫冻帧 / 回游戏 / 停后清理）应过，无需改产品。
- 包：仍 `C-65.11-98+debug-6-1+debug`。不装包、不杀 SB、不碰 `.53`、不拧匹配器。
- 证据：`tmp_shots/P0_DAY6_BIZREG_20260814_100215`。
- 脚本：`tools/zy_p0_day6_biz_reg.sh`。
- 三机 PASS：live/keep/back 金标 `12688231` `(701,447)`；keep 期 `keep=1`；Home `pixel_miss` + springboard；KEEP_AFTER=0；SB_CHG=0；FC_N=1；color_req=0。
- `.171`/`.149`：555/70；3274/70097。起止 PID 未变。
- 判定：Day6 完成。**不是 P0 全绿**。Day7 才第一周完成条件复核。
- 下一条唯一动作：见 §29。

## 29. 2026-08-14 P0 Day7 第一周完成条件复核

- 假设：5min 业务窗内无持续 relay/反复 UICreate/seq 长停/p95 秒级 age/卡屏。窗内日志按字节偏移。不改产品。
- 包：仍 `C-65.11-98+debug-6-1+debug`。不装包、不杀 SB、不碰 `.53`、不拧匹配器。
- 证据：`tmp_shots/P0_DAY7_WEEK1_20260814_103827`。
- 脚本：`tools/zy_p0_day7_week1.sh`（SEC=300）。
- 三机诚实 PASS：窗内 relay/UICreate/black=0；seq 推进；age p95 871/958/779；hit≥98.9%；color_req=0；SB_CHG=0；FC_N=1。
- 自动 AGE_SUSTAINED 含 reacquiring 高龄；诚实 active 连续≥2s 为 0/1/2。WATCH 开跑 4–8s seq 停。
- `.171`/`.149`：555/70；3274/70097。
- 判定：第一周完成条件（允许三机）复核通过。**不是四机周完成。不是产品全绿。**
- 下一条唯一动作：见 §30。

## 30. 2026-08-14 P1 Day8 session ACK

- 假设：在现有 zydaemon/ScriptRunner/embed 双写 `request_id`/`session_id` 与 run/ready/stop ACK；`state` 仍只 `idle|running|soft`（`WantsRun` 认 `state=running` 子串）。不新建 supervisor，不拧匹配器，不把 find 退回 HTTP。
- 自审修正：
  1. 直写 `embed_go` 的门禁不走 ScriptRunner → 必须在 embed accept 写 `.ziyan_session` ids，否则 stop_ack 空 id。
  2. 用户停若立刻写 stop_ack，仍在收尾的 embed 会假报 `ZY_E_STOP_TIMEOUT`。与软停同预算：≤1s 等线程退出再 ACK。
  3. 门禁唤醒漏 `unlock_req` 会把锁屏写成 GOLD_MISS。
- 包：`C-65.11-98+debug-7-3-1+debug`。SHA256 `8cd4f636dc7108251deaba537d60b0a4d3b4ccaafcd5901e6e072e4e0f16bcb7`。三机 dpkg 安装。未部署 `.53` / `.149` / `.171`。
- 证据：`tmp_shots/P0_DAY8_SESSION_ACK_20260814_114343`（上一窗 7-2：`..._113552`，`.101` GOLD_MISS 为 suspended 未解锁；`.112` 假 STOP_TIMEOUT）。
- 脚本：`tools/zy_p0_day8_session_ack.sh`。
- 三机 PASS：run_ack `accepted=1` RID 对齐；ready_ack 出现（`.112`/`.166` `fresh=1`；`.101` `fresh=0` WATCH）；金标 `12688231` `(701,447)`；stop_ack `state=idle accepted=1 keep_after=0` 含 RID；FC_N=1；color_req=0。
- `.171`/`.149`：TSDaemon 555 / 3274；SB 70 / 70097。未部署。
- 判定：Day8（允许三机）完成。**不是四机、不是产品全绿、禁宣称超越。**
- 下一条唯一动作：见 §31。

## 31. 2026-08-14 P1 Day9 Ensure/health

- 假设：Ensure 不以 PID 为就绪。成功 = `ziyan_framecap serve` + alive 心跳(≤12s) + FC_N=1。fresh 只写入 health_ack / `/health`，Ensure 与 Poll 都不得为新鲜帧阻塞。idle/Home `seq=0` 仍算控制面就绪。
- 自审：
  1. 若 Ensure 把 `lease=active` 当成功条件，停脚本/Home 后菜单无法再启动。
  2. 已有 serve 时禁止 kickstart（否则 FC_N=2）。心跳挂死也不准再 spawn。
  3. HTTP `/health` 与 `.ziyan_health_req` 只 peek 写 ACK，不采帧、不 sleep。
  4. 进程内不能诚实报全局 FC_N，ack 里 `fc_n=-1`；门外 ps 才是唯一计数。
- 包：`C-65.11-98+debug-8-1+debug`。SHA256 `830b70bc7dd911f9bb267e0e522ea7bfd3ff052a6272a0596e662395f418cd15`。三机 dpkg。未部署 `.53` / `.149` / `.171`。
- 证据：`tmp_shots/P0_DAY9_HEALTH_20260814_120329`。
- 脚本：`tools/zy_p0_day9_health.sh`。
- 三机 PASS：idle `ok=1 fresh=0`；wake 后 `fresh=1` provider=8；金标 `12688231` `(701,447)`；停后 health 仍 `ok=1`、KEEP=0、FC_N 全程 1；color_req=0。health_req 约 300ms 回 ACK。
- `.171`/`.149`：TSDaemon 555 / 3274；SB 70 / 70097。未部署。
- 判定：Day9（允许三机）完成。**不是四机、不是产品全绿、禁宣称超越。**
- 下一条唯一动作：见 §32。

## 32. 2026-08-14 P1 Day10 停止合同

- 假设：停止是一级功能。合同 = ACTIVE=0、KEEP=0、无 lua pidfile/embed/独立 lua、FC_N=1、抬指、藏 Toast、framecap 仍健康，且可再次运行。
- 自审：
  1. embed 把 framecap pid 写入 `.ziyan_lua_run.pid`。停后不删，SB 的 `scriptSessionActive` 会把活着的 framecap 当成脚本仍在跑，`release_screen` 被忽略。
  2. `stop_ack` 若在杀独立 lua / KeepRecycle 之前写，合同「无僵尸/KEEP=0」是假的。
  3. ScriptRunner 抢写 stop_ack 会在 keep 未拆时假完成。改为只由 framecap 写。
  4. 抬指/藏 Toast 走 `.ziyan_stop_cleanup`，SB 消费；Poll 不等待。禁止 FixSwipeNow（抢 Home key / dump 窗）。
- 包：`C-65.11-98+debug-9-1+debug`。SHA256 `f7071f1f89863a31c1a887f052ec65c9757cd5a394891afe20d5a099d4cf1e0d`。三机 dpkg。未部署 `.53` / `.149` / `.171`。
- 证据：`tmp_shots/P0_DAY10_STOP_20260814_122035`。
- 脚本：`tools/zy_p0_day10_stop.sh`。
- 三机 PASS：跑中 keep=1 pidfile=1 touchDown；停后 stop_ack `active=0 keep_after=0 pidfile=0 embed_alive=0`；cleanup `touch_lift=1 toast_hide=1`；再跑金标 `12688231` `(701,447)`；FC_N=1；health ok。
- `.171`/`.149`：TSDaemon 555 / 3274；SB 70 / 70097。未部署。
- 判定：Day10（允许三机）完成。**不是 100 次停（Day11）。不是四机、不是产品全绿、禁宣称超越。**
- 下一条唯一动作：见 §33。

## 33. 2026-08-14 P1 Day11 run/stop 100 次 + 异常恢复

- 假设：同一停止合同连跑 100 次仍干净；embed/runner 异常退出后 framecap 保持；禁止用重启 SB 当恢复。音量受控走已有 `.ziyan_menu_run_trig` / user_stopped，不按实体键。
- 自审：
  1. embed 线程退出后若留 `lua_run.pid` + `state=running`，zydaemon 会把已结束/崩溃脚本 revive 成环。
  2. 直写 `embed_go` 必须清 `user_stopped`，否则 100 次第二圈 WantsRun 永假。
  3. 同脚本在 `gEmbedStop=YES` 收尾时不能 `already_running` ignore，否则 OUT 被截断后永远等不到 ready。
  4. `ziyan_run` 对业务 `error()` 走 pcall+os.exit，不会写 `.ziyan_embed_crash`；崩溃合同看 boom 一次、会话 idle、framecap 仍在、可再跑。
  5. 音量菜单会 minimize；金标前必须再唤醒游戏，否则 lease=suspended 是环境不是匹配器。
- 包：`C-65.11-98+debug-10-2+debug`。SHA256 `429860055dec1e571e42b437d5879f6bb97dfb58c1d3d721e78fdc41e40b5518`。三机 dpkg。未部署 `.53` / `.149` / `.171`。
- 证据：`tmp_shots/P0_DAY11_CYCLE_20260814_131003`（100 次）+ `tmp_shots/P0_DAY11_CYCLE_20260814_133730`（唤醒后再跑金标）。
- 脚本：`tools/zy_p0_day11_cycle.sh`。
- 三机 100/100 run/stop：KEEP/pid/embed=0，FC_N=1，SB pid 不变，没有用杀 SB 恢复。音量 trig 典型 4/5。崩溃后 framecap pid 不变；补跑唤醒后 `.101` 5s / `.112` 10s 金标 `12688231 (701,447)`。
- `.171`：TSDaemon 555 / SB 70。`.149` 本窗 SSH 失败。未部署。
- 判定：Day11 主合同（100 次启停 + 不杀 SB）三机完成。音量不是 100 次实体键（S5 未做）。不是四机、不是 3h、不是产品全绿、禁宣称超越。
- 下一条唯一动作：见 §34。

## 34. 2026-08-14 P1 Day12 三机 30min

- 假设：Day8–11 生命周期改动后，debug-10-2 现包能 30 分钟 embed 找色长稳：session 保持 running、FC_N=1、SB 不换、color_req=0；停后合同仍绿；唤醒后再中金标。不跑 Home、不开 180m。
- 改动：新门禁 `tools/zy_p0_day12_30m.sh`。不改产品代码、不装新 deb、不杀 SB。
- SHA：仍 `429860055dec1e571e42b437d5879f6bb97dfb58c1d3d721e78fdc41e40b5518`。
- 证据：`tmp_shots/P0_DAY12_30M_20260814_134702`。
- 三机 PASS：`.101` n/hit 1609/1602；`.112` 1169/1165；`.166` 1843/1822。金标 `12688231 (701,447)`。idle_hit=0。SB_CHG=0。FC_N=1。stop_ack `active=0 keep_after=0 pidfile=0 embed=0`。再跑金标三机命中。embed_find 1609/1167/1840，color_req=0。
- OLS 中位 +0.0 / +0.0 / +2.2 KB/100s；ols −23.9 / −67.5 / −49.5（锯齿，不写成优于触动）。
- keep：开跑 KEEP_DURING=1；TTL 后 keep 旗落下（产品既有）；停后 KEEP=0。
- `.171`：TSDaemon 555 / SB 70。`.149`：TSDaemon 3274 / SB 70097。只读。
- 判定：Day12 30min（允许三机）PASS。**不是 3h、不是四机、不是 Z2、禁宣称超越。**
- 下一条唯一动作：见 §35。

## 35. 2026-08-14 P1 Day13 Gate C 30m

- 假设：Day12 embed 30min 未测 Home；debug-10-2 现包应能再过 Gate C（每分钟 Home→回 App→金标）。不重开 Home 钩子，不拧匹配器，不开 180m。
- 改动：仅把门禁 REPORT 标题改成 Day13/debug-10-2。不改产品代码、不装新 deb、不杀 SB。
- SHA：仍 `429860055dec1e571e42b437d5879f6bb97dfb58c1d3d721e78fdc41e40b5518`。
- 证据：`tmp_shots/P2_30M_C98_20260814_142422`。
- 三机 30/30 PASS：末分钟金标 `12688231` AP=8。`.101` Home_MS=1000 framecap=49105 SB=49125；`.112` Home_MS=0~2000 framecap=93352 SB=93150；`.166` Home_MS=1000 framecap=64880 SB=64900。全程 pid 不变，FC_N=1。APP_RETRY 典型 4。
- 停后三机：`state=idle` KEEP=0 pidfile=0 embed=0 FC_N=1 front=`com.xztl.ios`。
- `.171`：TSDaemon 555 / SB 70。`.149`：TSDaemon 3274 / SB 70097。只读。未向观察机发 Home。
- 判定：Day13 Gate C 30m（允许三机）PASS。**不是 3h、不是四机、不是 Z2、禁宣称超越。**
- 下一条唯一动作：见 §36。

## 36. 2026-08-14 P1 Day14 A1 启动标记 / Z1-VIS

- 假设：旧 A1 FAIL 是启动标记写在 prewarm（≤8s）之后，门禁只睡 3s。提前写 `.ziyan_lua_embedded` / `embed_alive` 后 A1 应过。find 仍在 prewarm 后才跑。不拧匹配器、不重开 Home 钩子。
- 改动：`ZiYanLuaEmbed.m` 线程入口与 Poll 接受后、prewarm 前写启动标记；prewarm 中途 stop 清标记。门禁 A1 改为最多 15s 轮询 ack/session/标记；解锁后再 Home；OUT 带 host/pid；默认跳过 `.53`。
- SHA：`5a5dbacfeb5094a19d7ebd217bc566a87505a95810410d6313f7f800fd8b49ea`。ios7 SHA 仍 `0a6325ca9a091a864a6c8e6e226be2dc952e39890c833702652b51a09ea55d3c`。
- 证据：`tmp_shots/Z1_VIS_DEBUG10_3_20260814/REPORT.md`；串行 `.101` `tmp_shots/RUN1_GATE_20260814_152506_101_88821`。
- A1 三机 PASS（`lua_embedded` t≈4–7）。`.101` 解锁 ok，Home 10 次仍游戏前台；找色 `reacquiring` / `lease=suspended`。首轮并行撞同一 STAMP，不作齐。
- 未改 ios7.lua。`.112` Desktop 色点问题仍在，本窗没走到桌面找色。
- `.171`：TSDaemon 555 / SB 70。`.149`：3274 / SB 70097。只读。
- 判定：A1 假 FAIL 已修并上机。**Z1-VIS 未齐。不是 3h、不是四机、不是 Z2、禁宣称超越。**
- 下一条唯一动作：见 §37。

## 37. 2026-08-14 装包后 Home（10-4 / 10-5）

- 假设：A0 失败是 thin 在 AX front=nil 时 `skip_all`，与注释「仍发主 Home」矛盾。不重开 Home 钩子。
- 10-4：未知前台发 simulate。三机 `issued=1`，`front_bid` 不变。
- 10-5：`processState==Foreground` 才把 `front_bid` 当 expected bid 走 C98。三机实测 `fg=0`，SBS+simulate 仍不改 `front_bid`。
- SHA：`6478c29a5e26d0a138424d5c84455e1834cac553abaee5c95fbb4b04b4ee7be4`。
- 证据：`tmp_shots/HOME_UNKNOWN_FRONT_20260814/REPORT.md`。
- `.171`：TSDaemon 555 / SB 70。`.149`：3274 / SB 70097。`tmp_shots/TS_OBS/20260814_155228`。
- 判定：skip_all 已修。**Home 观测未齐。Z1-VIS 未齐。同一症状两刀，禁止第三刀盲改 Home。** 不是 3h、不是四机、不是 Z2、禁宣称超越。
- 下一条唯一动作：见 §38（已改为减法 + 观测 writer，不再盲改 Home 动作）。

## 38. 2026-08-14 debug-10-7 减法 / debug-10-8 观测 / Z1-VIS

- 10-7：删 10-4/10-5 未知前台旁路。AX 空 → `skip_all`。三机探针 `front_bid` 仍游戏、native 文件停在重启前、游戏进程已不在。证据 `tmp_shots/HOME_SUBTRACT_10_7_20260814/REPORT.md`。
- 10-8：不发 Home。周期采样 AX=nil 时写 `source=unavailable`；旧 App `processState!=Foreground` 则唯一 writer 发布 SpringBoard。三机 `stale_not_fg was=com.xztl.ios`，`front_bid=com.apple.springboard`。证据 `tmp_shots/FRONT_OBS_10_8_20260814/REPORT.md`。
- SHA：`015b0a1ae1ffb7fdeab45b5368238c80d513b4a120154ac982b1c0247dd62b80`。回滚 `.../rollback/pre_...debug-10-7-1..._20260814_162953`。
- Z1-VIS 顺序：`.101` `RUN1_GATE_20260814_163329_101_46784` BUSINESS_PASS；`.166` `…_163654_166_48263` BUSINESS_PASS；`.112` `…_163417_112_47268` A0 PASS、A1 标记未见、A2 VISION_STALE/`stale_frame`。禁改 ios7.lua。禁重开 Home 钩子。禁拧匹配器。
- 触动只读 `tmp_shots/TS_OBS/20260814_163329`：`.171` TSDaemon 555 / SB 70；`.149` 本窗 TSDaemon 未见、SB etime 00:57（观察机自发，未部署 ZiYan）。
- 判定：**A0 装包后前台观测已齐。Z1-VIS 未齐（`.112` Desktop/stale_frame，`.53` 暂停）。** 不是 3h、不是四机、不是 Z2、禁宣称超越。
- 下一条：见 §39。

## 39. 2026-08-14 debug-10-9 找色=当前屏幕

- 用户纠偏：触动对当前画面找色，不管前台是哪个 App；颜色对上取色器即命中。
- 删：Lua `VISION_STALE` 硬 gate；embed `front_mismatch` / Home 拒扫 / 帧龄>1200 硬 miss；color_req/findImage/ocrRoi 按 bid 硬拒。留：无像素才 reacquiring；bid 错位只催帧。
- SHA：`1b1abd1041b3a76d9a98485ed3ef10f442df6820e6b7a966a01e269b354a31cb`。回滚 `.../rollback/pre_...debug-10-8-1..._20260814_165124`。
- Z1-VIS：`.101` `RUN1_GATE_20260814_165403_101_61191` BUSINESS_PASS；`.166` `…_165652_166_62172` BUSINESS_PASS；`.112` `…_165449_112_47268` A0/A1 PASS，A2 `pixel_miss`/`VISION_MISS`（先前是 `stale_frame`）。禁改 ios7.lua。禁拧匹配器。
- 触动只读 `tmp_shots/TS_OBS/20260814_165346`：`.171` TSDaemon 555 / SB 70；`.149` TSDaemon 562 / SB 69。
- 判定：找色逻辑已与触动对齐到「扫当前屏」。`.112` 剩下桌面色点与脚本不一致。不是 3h、不是四机、不是 Z2、禁宣称超越。
- 下一条：`.112` 要过 Z1-VIS 只能用户改 Desktop 色点；禁止再给找色加 App 身份 if。3h/180m 仍禁。



- **P4 empty-SHM 首帧候选（2026-08-31）**：本地合同 `P4_FRAMECAP_EMPTY_SHM_ACTIVE_EVIDENCE_CONTRACT=PASS`；rootful/rootless 包 SHA=`2e7bf7e64d4ed9439880f0a73104aaebddbe77fba2253e19e6c01c687647ddbf`/`11537e3569371ef0841a8dd36bd03a012932d36a42b3cbac0ff68b2f4c402745`。`.101` 已安装并在既有 zydaemon owning layer 下受控替换 framecap，当前后检 `FC_N=1`、SB/BB=`12443/12442`、P4/P3/GameEntry/touch/bridge/recovery transient 全 absent；但前台为 `com.apple.springboard`、canonical `frame_seq=0`，未触发新 P4 request，故保持 `PRE_BLOCKED/INCONCLUSIVE`，不升级 `DEVICE_PASS`。证据：`tmp_shots/P4_EMPTY_SHM_FIRST_FRAME_CANDIDATE_20260831_0340/VERDICT.md`、`current_readonly_20260831.txt`、`replacement_verified_readonly.txt`。

## 40. 2026-09-02 chat capability `.101` / rootful `17-125`

- **部署**：按 checkpoint 唯一动作将 rootful `17-125` 受控幂等部署到 `.101`，没有触发 SpringBoard/BackBoard 重载；包版本 `0.0.92-8-161-205-C-65.11-98+debug-10-38-17-125+debug`，包 SHA256 `1aecccd061176b316e91c9a9bc7becf95197481db26f36de26a11ac4d05079b3`。证据 `tmp_shots/DEPLOY_ROOTFUL_20260902_20260902_222432_101/VERDICT.md`。
- **部署回读**：SpringBoard PID `51008 -> 51008`，自动解锁 `ok`，`display_locked=0`，`FC_N=1`；设备回滚快照路径见部署 `device.txt`。
- **chat gate**：仅测试 `.101`，目标 `com.xztl.ios`。证据 `tmp_shots/CAPABILITY_chat_DEVICE_101_20260902_222529_79091/VERDICT.md`。
- **设备事实**：`real_device=true`，`input=1;send=1;multi_turn=1`，但 `result=false`，`reason=no_message`；`pipeline_ok=false`、`module_ok=false`；包版本匹配，`FC_N=1`，停止后 `active=0/embed=0`。
- **判定**：`DEVICE_INCONCLUSIVE`。这不是传输中断，也不是清理 PASS；chat 业务结果尚未成立。`.112/.166/.53` 未因本轮结果推进。
- **当前阻塞层**：chat 业务链的消息产生/回显路径仍未完成归因；暂不改视觉、触控、framecap 或设备范围。
- **唯一下一步**：只读诊断 `.101` 的 `input/send/multi_turn -> no_message` 单一归属层；确认后仅修该层并回 `.101` 复验。
