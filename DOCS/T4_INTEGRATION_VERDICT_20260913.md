# t4 端到端集成判定与最终诚实报告

- 生成时间：2026-09-13 20:15 +0800
- 执行者：device-verifier（真机验收工程师）
- 依据：工程审计总提示词 第二十三、二十四、二十五、二十六、二十八条
- 原始证据：`tmp_shots/device-verifier-t4-integration/`（`EVIDENCE_RAW.md` + `fleet-*.txt` + `apt/` + `apt-dl/`）

> 本报告只描述**本轮真实执行过**的动作。所有未执行项一律标注「未执行」。
> 完成等级严格区分：**代码已实现 / 本地已验证 / 集成已验证 / 真机已验证 / 端到端已验证**。

---

## 0. 最重要的结论先说

**综合判定：FAIL（不可宣布端到端闭环完成）**

| 项 | 判定 |
|---|---|
| 代码编译 | **PASS** |
| APT 仓库（公网托管 + 扁平源 + 签名） | **PASS** |
| Cydia/Sileo 源可添加性 | **PASS（源侧）** / **UNVERIFIED（真机 GUI 内实际操作）** |
| 热更新分发 | **FAIL**（见 §3 的 F3：分发内容落后于当前版本） |
| 设备兼容性检查 | **PASS**（服务端逻辑）+ **UNVERIFIED**（真机端到端） |
| **端到端闭环（第二十三条那条链）** | **FAIL** |
| 设备守护可用性（framecap/zydaemon） | **FAIL**（5 台中 4 台守护全灭） |

**两条关键失败**（本轮新发现，均为真机实测，非推测）：

1. **F1 [blocker] 线上拆分包丢失全部维护脚本** → 5 机中 4 台 ZiYan 守护进程全部消失（FC_N=0、zydaemon=0），对照 t1 验收时五机 FC_N=1。设备功能实际处于**停摆**状态。
2. **F2 [blocker] 端到端数据面在迁移后无任何新事件** → 服务器 43 条事件中最新为 14:41（且那条是人工 E2E 注入），**19:00 之后 0 条**，而五机迁移发生在 19:34–19:55。

---

## 1. 六大功能真实完成等级

| # | 功能 | 真实完成等级 | 判定 | 依据（可复算证据） |
|---|---|---|---|---|
| 一 | ZiYan 自动错误收集 | **代码已实现 + 本地已验证 + 真机历史已验证**（迁移后**未**重新验证） | **PASS（历史）/ UNVERIFIED（当前）** | 设备存在 43 条历史事件与真实积压（.101 待传 12 条、.61 待传 27 条）；模块 `ErrorReporter.lua` 在包内且 t1 实测 `require` 成功 |
| 二 | HTML / Web 管理页 | **本地已验证** | **PASS（本地）/ BLOCKED（公网暴露）** | `tools/ziyan_log_server/index.html` 单行修复真实；fixture 与 live 两模式我独立复跑均 exit 0、apiEvidence 9 项全 ok |
| 三 | 服务器关闭时日志不丢（离线等待→恢复续传） | **本地已验证**（t3 契约测试 11/11 + 积压真实存在） | **PASS（本地）/ UNVERIFIED（真机续传）** | `.upload_spool` 真机积压 12/27 条证明「服务器不可达时确实入队」；但**未见积压被成功上传的证据**（§4） |
| 四 | HTML 一键下载错误日志 | **本地已验证 + 真机历史已验证** | **PASS（本地）/ UNVERIFIED（当前设备）** | 我独立复跑导出落盘成功；但当前 4 台守护已死，无法再触发 |
| 五 | AI 自动分析错误并修复 | **未执行** | **UNVERIFIED** | 未发现 `/api/ai/*` 端点（实测 404）；本轮**未执行**任何 AI 分析→修复→重验链路 |
| 六 | Git 同步 | **集成已验证** | **PASS（main↔GitHub）/ 未完成（origin 本地仓）** | `github/main` = 本地 HEAD = `4309957`（实测一致）；本地 `子砚触控GIT` 落后 158 / 领先 124（未同步） |
| 附 | APT / Cydia / Sileo | **端到端已验证（源与包侧）** | **PASS** | 根路径 200、Release/InRelease/Packages/Packages.gz 全 200、两个拆分包可下载且 SHA256 与 Packages 声明逐字节一致、GPG 验签 Good signature、`.101` 上 `apt-get update` 无告警 |
| 附 | 热更新 | **集成已验证（服务在线）** | **FAIL（内容落后）** | manifest 最高版本 = **164-2**，**不含 165**；当前设备 165-2 查询得 `no_update`（不会升级到新包） |
| 附 | 设备兼容性检查 | **集成已验证** | **PASS** | 实测 `os=12.0` → `reason=device_incompatible`；`os=15.8.8` → `no_update` |

### 六大功能之外的整机可用性（t1 与本轮对照）

| 设备 | t1 验收时 | 本轮（迁移后） | 变化 |
|---|---|---|---|
| .101 | FC_N=1 | **FC_N=0, ZY_N=0** | **回归** |
| .112 | FC_N=1 | **FC_N=0, ZY_N=0** | **回归** |
| .166 | FC_N=1 | **FC_N=0, ZY_N=0** | **回归** |
| .53 | FC_N=1 | **FC_N=0, ZY_N=0** | **回归** |
| .61 | FC_N=1 | FC_N=1, ZY_N=1 | 未回归（其 framecap 于 19:56:15 重启） |

---

## 2. F1 [blocker]：线上拆分包丢失全部维护脚本 → 四机守护全灭

### 2.1 现象（真机实测，4 次采样跨 2.5 分钟稳定）

```
.101 FC_N=0 ZY_N=0 | .112 FC_N=0 ZY_N=0 | .166 FC_N=0 ZY_N=0 | .53 FC_N=0 ZY_N=0
.61  FC_N=1 ZY_N=1
launchctl print system/com.ziyan.framecap → Could not find service ... in domain for system
```

### 2.2 根因（逐层可复算）

**(a) 线上 deb 的 control 归档只含 `control`，没有任何维护脚本：**

```
线上 com.ziyan.ziyan-rootful  (sha256 874cca6d612721dc9a4f33f9f7284434a8387f1869a503e9b2772a3943afb1a7)
  ar 成员顺序：debian-binary, control.tar.gz, data.tar.lzma   ← 顺序正确（t2 自述的缺陷 a 已修）
  control.tar.gz = 378 B，唯一成员 ./control
  postinst ABSENT / preinst ABSENT / prerm ABSENT / postrm ABSENT

线上 com.ziyan.ziyan-rootless (sha256 517cc8e193dd0f60c9cf7e62769fdc08d1f7b583b1cb225542ea998d016b9cef)
  同样：control.tar 仅含 ./control

对照 本地 packages/…17-165-1…deb：
  control.tar.gz = 8446 B，成员 ./control ./postinst(23278 B) ./preinst ./prerm
```

**(b) 设备 `dpkg/info` 证实脚本从未安装：**

```
.101/.112/.166 → 仅 com.ziyan.ziyan-rootful.list 与 .md5sums
.53/.61        → 仅 com.ziyan.ziyan-rootless.list 与 .md5sums
（无 .postinst / .preinst / .prerm）
```

**(c) postinst 改写过的 plist 全部回退为「包内原版」**（本轮实测哈希，与 t1 记录对照）：

| 文件 | 当前设备哈希 | t1 时 postinst 改写版应为 | 结论 |
|---|---|---|---|
| framecap.plist | `c7360c52…` | `06e322ac…` | 回退 |
| zydaemon.plist | `9a857940…` | `b58f1e2c…` | 回退 |
| fscloak.plist | `6bb129ad…` | — | 包内原版 |
| engine.plist | `1a3eb462…` | `6660f771…` | 回退 |

**(d) 时间线吻合**（`dpkg/status` mtime）：`.101` 19:34:36 / `.53` 19:47:33 / `.112` 19:54:42 / `.166` 19:54:54 / `.61` 19:55:16。
守护消失与迁移时刻一致。

### 2.3 为什么脚本缺失会导致守护全灭

- 旧统一名包 `com.ziyan.ziyan` 被 `Conflicts/Replaces` 取代 → dpkg 先执行**旧包 prerm**，其 `stop_daemons()` 会 `launchctl bootout` 并 `killall -9 ziyan_framecap / ziyadaemond / wnriakwyww`。
- 新拆分包**没有 postinst**，因此**没有任何步骤把守护重新激活**（ZiYan 的设计是 postinst 只落盘、由人工授权重载；但连 plist 的机型改写也没人做）。
- 结果：守护被停掉后无人重启；`.61` 的 framecap 恰好在迁移后 1 分钟被外部拉起，故侥幸存活。

### 2.4 受影响的真实用户路径

新用户按 `https://apt.ziyanapp.top/` 安装拆分包时：
1. **`/private/var/mobile/Media/ZiYan/ZYCV/res/错误报告` 及 `.upload_spool` 不会创建** —— 该目录**只在 postinst 里 `mkdir`**（postinst:38-39），payload 中**不含**该目录。→ **功能一（错误收集）与功能三（离线等待）在全新区上直接失效**。
2. `com.ziyan.ziyan.runtime_scheme` 与 `$ROOT/var/.ziyan_runtime_scheme` 不会写入。
3. launchd plist 不会被改写成机型适配版（rootless 的 argv0、PATH 等）。
4. `uicache` 不会执行（新装机桌面图标可能不出现）。

**注**：当前五机的这些目录仍存在，是因为**旧 postinst 在更早的安装中已创建**——属历史遗留，不代表新装可用。这是「看起来完成」的典型漏洞。

---

## 3. F2 [blocker]：端到端数据面在迁移后为零

```
GET /api/logs?limit=2000 → total=43
  最早 2026-09-11 23:05:43 ；最新 2026-09-13 14:41:23
  设备分布 {D10AP:5, unknown:23, iOS-1242x2208@3:10, D101AP:4, '':1}
  19:00 之后事件数 = 0
  最新一条 message = "E2E upload from .101 on 164-3"  ← 人工 E2E 注入，非自然上报
```

五机迁移发生在 19:34–19:55，**迁移后没有任何一台成功上报**。
因此「真机产生错误 → 自动收集 → 上传 → Web 可见」这条链**在本轮未被证明可用**；
现有 43 条只能证明**历史**曾经打通。

---

## 4. 反向自检（第二十六条）：最容易怎么作弊，当前有没有这种漏洞

| 最省事的作弊方式 | 当前是否踩中 | 说明 |
|---|---|---|
| 用「APT 返回 200」代替「Cydia 真的装得上」 | **已规避** | 我实测下载 deb 并核对 SHA256、GPG 验签、设备 `apt-get update`，未只看状态码 |
| 用「57MB 包已下载」代替「安装后 ZiYan 能跑」 | **已规避** | 我实测进程与守护状态，发现 FC_N=0 |
| 用「历史 43 条事件」代替「当前闭环可用」 | **已规避** | 我核了事件时间戳，发现迁移后为 0 条 |
| 用「文件存在」代替「功能完成」 | **已规避** | 发现 `错误报告` 目录存在但**只靠历史 postinst**，新装会缺 |
| 用「main 已 push」代替「六项功能都完成」 | **已规避** | Git 单独判 PASS，未外溢到其他功能 |
| 用「服务在 18091 起来了」代替「公网可用」 | **已规避** | 实测 `apt.ziyanapp.top:18091` 不可达（000），公网暴露仍 BLOCKED |
| 用「我本地测过」代替「真机验证」 | **已规避** | 六大功能逐条区分本地/真机/端到端等级 |
| 用「t1 曾经 PASS」代替「当前仍 PASS」 | **已规避** | 正是本轮发现 t1 的 FC_N=1 已回归为 0 |

**已发现的漏洞（不宣布完成，继续执行）**：F1、F2 均为本轮实测出的真实回归，**当前结果存在「看起来完成」的漏洞**——若只看 t1 报告与 APT 200，会误判为闭环打通。

---

## 5. BLOCKED 项（具体对象 / 已尝试动作 / 尝试结果 / 解除条件）

### B1 公网日志收集（HTML 页面公网暴露）
- **阻塞对象**：缺公网常驻主机 + 传输加密/鉴权方案。`apt.ziyanapp.top` 是 GitHub Pages **静态站**，无法跑常驻进程。
- **已尝试**：`curl http://apt.ziyanapp.top:18091/` → `000`（不可达）；本机 `lsof` 确认仅 `*:18091` 本机监听。
- **尝试结果**：BLOCKED。局域网可用（`192.168.31.81:18091`）。
- **解除条件**：一台可跑常驻进程的公网主机 + HTTPS/WSS + 鉴权。

### B2 设备侧「导出到桌面」与离线续传的真机验证
- **阻塞对象**：属 t1 范围；且当前 4 台守护已死（F1），无法触发。
- **已尝试**：本轮实测五机进程状态；查询服务器事件新鲜度。
- **尝试结果**：UNVERIFIED（迁移后 0 条上报）。
- **解除条件**：修好 F1（恢复守护）后，在真机上重跑「产生错误→入队→恢复→上传」。

### B3 iOS 端 Lua 5.3 与本地 5.4.6 的行为差异
- **已尝试**：t1 用设备自带 `lua5.3` 实跑 5 个 lua 模块，`loadfile` 全 OK。
- **尝试结果**：模块级 PASS；**语义级差异 UNVERIFIED**。
- **解除条件**：在设备 5.3 上跑完整业务脚本回归。

### B4 人工授权的注入重载（t1 C10 延续）
- **阻塞对象**：需人工授权；postinst 按设计不重载。
- **已尝试**：本轮**未执行**（遵守纪律）。
- **尝试结果**：UNVERIFIED。当前守护已死，连「旧镜像在跑」都不成立（是不跑）。
- **解除条件**：人工授权后重载并复采运行镜像。

---

## 6. 仍未完成项与失败原因

| 项 | 原因 |
|---|---|
| **F1 拆分包缺维护脚本** | 构建/打包环节未把 `postinst/preinst/prerm` 放进 `control.tar`（线上两个包均只含 `control`）。**失败原因：打包缺陷**，非环境问题。 |
| **F1 衍生：四机守护全灭** | 旧包 prerm 停守护 + 新包无 postinst 重启 → 无人拉起。 |
| **F2 迁移后 0 上报** | 与 F1 同源（守护不在，上报链路无从触发）；亦无法排除配置问题。 |
| **F3 热更新分发落后** | manifest 最高 164-2，**不含 165**；当前 165-2 设备查询得 `no_update` → 已发布的新版本不会通过热更新触达用户。 |
| **F4 Git origin 未同步** | `子砚触控GIT` 落后 158 / 领先 124（t5 范围，未执行）。 |
| **F5 AI 自动分析未执行** | 未发现 `/api/ai/*`；本轮未做任何 AI 分析→修复→重验。 |
| **F6 公网 Web 未上线** | 见 B1。 |
| **F7 包体 57MB 未优化** | t2 自述；本轮未处理。 |

---

## 7. 需要人工操作

1. **【最高】修打包缺陷 F1**：让拆分包带上 `postinst/preinst/prerm`（与 `packages/…17-165-1/2…deb` 一致），重新发布并重装五机；随后确认五机 `FC_N=1`、`ZY_N=1`。
2. **【高】补 `错误报告`/`.upload_spool` 目录创建**：要么进 payload，要么由 postinst 建（当前仅后者），否则新用户装完即缺。
3. **【高】修 F3**：把 165 双包纳入 hotupdate manifest，或明确热更新暂不覆盖拆分包。
4. **【中】授权注入重载**：解 C10/当前「守护不跑」状态。
5. **【中】同步 origin（子砚触控GIT）**：t5。
6. **【决策】公网日志收集方案**：见 B1。

---

## 8. 第二十八条最终报告（按提示词格式）

```
==============================
ZiYan 多 Agent 开发结果
==============================

实际调用的 Agent：
  3 个成员（device-verifier 真机验收/复核、apt-publisher APT/发布、web-queue Web/离线队列）
  + captain（集成判定与手工落 verdict、接管 t6）
  注：本报告只依据各成员落盘的**证据文件**判定，未采信任何口头"完成"。

实际完成：
  165 双包五机真机安装+验收（t1，五机串行、可复算）
  Web 单行修复 + 两种验收模式（t3/t7，t8 复核 pass）
  APT 公网源打通（根路径 404 修复，拆分包上线，签名可验）
  Git main 推送 GitHub

代码修改：
  编译阻断 2 处（t1 前置）
  index.html 单行（buildQuery→qstr）
  test_admin_ui.mjs（跨平台/--live/exit-code 门禁/ sweep 断言）
  test_offline_queue_contract.py（夹具隔离/--self-test/计数更正）

编译：            PASS
错误自动收集：    PASS（历史）/ UNVERIFIED（迁移后未复验）
离线日志等待上传：PASS（本地契约 11/11 + 真机积压 12/27）/ UNVERIFIED（真机续传）
HTML / Web：      PASS（本地）/ BLOCKED（公网暴露）
一键下载日志：    PASS（本地）/ UNVERIFIED（迁移后守护已死）
热更新：          FAIL（manifest 不含 165，见 F3）
AI 错误分析：     UNVERIFIED（未执行，未发现 /api/ai/*）
真实设备问题修复：FAIL（F1：四机守护全灭；t1 时 FC_N=1 已回归）
Git：             PASS（main↔GitHub）/ 未完成（origin 本地仓落后 158）
APT：             PASS（端到端可复算）
Cydia / Sileo：   PASS（源侧：根路径 200+扁平源+签名可验+apt update 无告警）
                  UNVERIFIED（真机 GUI 内手动添加源并安装）
设备兼容性检查：  PASS（服务端逻辑，实测 device_incompatible）
端到端闭环：      FAIL

仍未完成：
  F1 拆分包缺维护脚本（blocker）→ 四机守护全灭
  F2 迁移后端到端 0 上报（blocker）
  F3 热更新分发落后于当前版本
  F4 Git origin 未同步（t5）
  F5 AI 自动分析未执行
  F6 公网 Web 未上线
  F7 包体 57MB 未优化

失败原因：
  F1：打包环节未把 postinst/preinst/prerm 放进 control.tar（线上两包 control.tar 仅含 control）
  F1′：旧包 prerm 停守护 + 新包无 postinst 重启 → 守护无人拉起
  F2：与 F1 同源
  F3：165 未加入 hotupdate manifest
  F5：未执行
  F6：GitHub Pages 静态站无法跑常驻进程

BLOCKED 原因：
  B1 公网日志收集：缺公网常驻主机 + 加密/鉴权（apt.ziyanapp.top:18091 实测不可达）
  B2 设备侧导出/续传真机验证：待 F1 修复
  B3 Lua 5.3 vs 5.4.6 语义差异：未做语义级回归
  B4 注入重载：需人工授权（本轮未执行）

需要人工操作：
  1) 修 F1 打包缺陷并重新发布/重装、复验五机 FC_N=1/ZY_N=1
  2) 补 错误报告/.upload_spool 目录创建（新装不可缺）
  3) 修 F3（165 纳入热更新或明确不覆盖）
  4) 授权注入重载
  5) 同步 origin（子砚触控GIT）
  6) 决策公网日志收集方案
==============================
```

---

## 9. 边界与纪律声明

- **`.61` 结论**：`.61` 全轮参与（rootless 主验收机），本轮给出独立实测（FC_N=1、包名 `com.ziyan.ziyan-rootless` 165-2、framecap 于 19:56:15 存活）。因此**本报告不是「缺 .61」的情形**；但**仍不得宣布主计划真机 PASS**，原因是 **F1/F2 为实测失败**，而非缺 .61。
- 本轮**未执行**：任何 sbreload / ldrestart / 杀 SpringBoard 或 backboardd；未动 `.149`/`.171`；未改 `lua/objc/vendor/Agent/Makefile/control/packages`；未重建 deb；未做注入重载。
- 本报告写入范围：`DOCS/`（本文件）与 `tmp_shots/device-verifier-t4-integration/`（原始证据）。
- 每条 PASS 的证据路径见 §1 表格与 `EVIDENCE_RAW.md`；每条 FAIL/BLOCKED/UNVERIFIED 的实测动作见 §2–§5。
