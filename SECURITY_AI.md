# ZiYan SECURITY_AI — 全自动越狱隐藏 + 智能反检测（7.6.3-R8）

> **用途**：学习 / 自动化测试 / 自身防御研究。禁止用于非法用途。  
> **阶段**：7.6.3-R8.4.8  
> **包**：`0.0.92-8-122`（Defense + Shadow essential + 桌面 hide-once；停用 AFC）  
> **详述**：`子砚工程防御/项目防御说明.txt`  
> **设备**：`.166` rootful iPhone7 iOS13 · `.53` rootless iPhone8Plus iOS16  
> **硬约束**：不修改找色/点击锁定；指纹 Hook **不**注入 SpringBoard/backboardd；桌面图标屏蔽在 ZiYanVol（**8-122：开 App 隐一次，禁回 SB 持续检查**）

## 1. 目标与硬约束

| 约束 | 说明 |
|------|------|
| 双路径 | rootful `/var/mobile/Media/ZiYan` · rootless `/var/jb/var/mobile/Media/ZiYan` |
| 不伤系统 | **禁止**对 SpringBoard / backboardd 等关键进程装伪造 Hook |
| 可恢复 | 退出 / 卸载 / 重启后不得残留假指纹；`cleanup_flag` 标记 dirty/clean |
| 禁止 | 单机 IP 特判、触动/XXTouch 私有 API、硬编码物理点击 |

## 2. 七套开源资料（原理学习，不拷贝私有实现）

| # | 资源 | 许可证倾向 | 本项目用法 |
|---|------|------------|------------|
| 1 | [Free-RASP-Capacitor](https://github.com/talsec/Free-RASP-Capacitor) | 免费核心 | 自身完整性 / 注入监控思路 |
| 2 | [ios_re_jb_detection](https://github.com/crifan/ios_re_jb_detection) | 开源文档 | 检测面清单 → 伪造返回 |
| 3 | [iOSSecuritySuiteBypass](https://github.com/dtcalabro/iOSSecuritySuiteBypass) | 红队学习 | 本地模拟突破验收 |
| 4 | [awesome-game-security](https://github.com/gmh5225/awesome-game-security) | 列表 | 防护分层思路 |
| 5 | [Unified_Prompt_Guard](https://huggingface.co/ynyg/Unified_Prompt_Guard) | 需自查卡 | 可选 ONNX 权重 |
| 6 | [jailbreak-detector-v5](https://huggingface.co/vincentoh/jailbreak-detector-v5) | 需自查卡 | 可选 ONNX 权重 |
| 7 | [mmbert-jailbreak-detector-merged](https://huggingface.co/llm-semantic-router/mmbert-jailbreak-detector-merged) | 需自查卡 | 可选 ONNX 权重 |

### 模型落地诚实说明

iPhone 7/8 存储与 Theos deb 体积无法默认捆绑三套 Transformer 权重。  
**默认运行**：`ZiYanDefenseAI` 本地启发式评分（阈值词来自检测面）。  
**可选**：将转换后的 `*.onnx` 放到 `Media/ZiYan/models/`（脚本：`tools/ziyan_defense/fetch_models.sh`）。  
**HF 拉取（已授权，镜像 `https://hf-mirror.com`）→ `vendor/hf_models/`：**

| 仓库 | 本地目录 | 状态 |
|------|----------|------|
| `ynyg/Unified_Prompt_Guard` | `ynyg__Unified_Prompt_Guard/` | 权重续传中（约 1.06GB） |
| `vincentoh/jailbreak-detector-v5` | `vincentoh__jailbreak-detector-v5/` | **完整**（adapter ~30MB） |
| `llm-semantic-router/mmbert-jailbreak-detector-merged` | `llm-semantic-router__mmbert-jailbreak-detector-merged/` | **完整**（~1.15GB） |
| `ynyg/Unified_Prompt_Guard` | `ynyg__Unified_Prompt_Guard/` | **完整**（~1.06GB） |

清单与说明：工程目录 **`大模型/三大模型.txt`**（三模型软链 + 训练/测试/是否联网说明）。  
物理权重：`vendor/hf_models/`（`大模型/` 内为软链，避免重复占盘）。  
真机：`/var/mobile/Media/ZiYan/ZYCV/res/models/`（旧 `Media/ZiYan/models` 自动迁入）（双机已同步，约 2.4GB）。  
同步：`tools/ziyan_defense/sync_models_to_devices.py`（tar 管道）。  
运行时：启发式 + `models_status.txt` 权重在位；**默认不自动联网**；**不**在 iPhone7/8 进程内跑满 Transformer。

## 3. 组件结构

```
objc/tweak/defense/
  ZiYanDefense.{h,m}      # 指纹 + Hook + cleanup
  ZiYanDefenseAI.{h,m}    # 突破检测 / Toast 延迟退出
ZiYanDefense.plist        # Filter=UIKit；ctor 再排除系统进程
layout/.../config.plist   # Enabled / ExcludedBundles
```

注入：`ZiYanDefense.dylib` → UIKit 进程；`ZDIsSystemCriticalProcess()` 立即返回。

## 4. 随机指纹字段

每次生成（或读取已有 `defense_fingerprint.plist`）：

- `model`（如 iPhone15,2）
- `systemVersion`
- `name`
- `idfv`
- `lanIP` / `wanIP`

## 5. Hook 面（第三方 App · 8-69 Shadow essential）

**Filter**：`com.apple.UIKit` + `com.ziyan.ziyan`（**不写死游戏 Bundle ID**）。

| API | 行为 |
|-----|------|
| `UIDevice` model/systemVersion/name/identifierForVendor | 返回指纹 |
| `sysctlbyname(hw.machine/hw.model)` / `uname` / `getifaddrs` | 假型号/名称/LAN |
| `stat` / `lstat` / `access` / `open` / `fopen` | 越狱路径 → ENOENT |
| `getenv` | 敏感 DYLD/_MSSafeMode → NULL |
| `_dyld_get_image_name` | 越狱 dylib 名伪装 |
| `NSFileManager` fileExists… | 越狱路径 → NO |
| `UIApplication canOpenURL:` | cydia/sileo/filza 等 → NO |

关闭时：`gHooksOn=NO` 透传；冷启清指纹。**不碰 AFC。**

## 6. AI / 突破流程

1. 监控 `defense_bypass_trig.txt`（验收用）或内部证据。  
2. `scoreEvidence` → conf；`>0.85` 写 `defense_break.flag` + 尝试 `defense_exit_toast.txt`。  
3. 分析中退出：`shouldDeferExitWithToast` 提示「游戏突破自身防御，等待分析结束恢复」，最长约 10s。  
4. `touch defense_shutdown_trig` → `shutdownAndRestore`（删指纹、`cleanup=clean`、`active=0`）。

## 7. 日志 / 状态

- `.../Media/ZiYan/defense.log`
- `.../Media/ZiYan/defense_status.txt`（active/bid/model/hooks）
- `.../Media/ZiYan/defense_fingerprint.plist`
- rootless 路径自动落 `/var/jb/var/mobile/Media/ZiYan`（与现有 media 解析一致）

## 8. 双机 5 项验收（8-48 已跑）

见 `tmp_shots/PHASE763R8/DEFENSE_DUAL_TEST_REPORT.md`（`tools/ziyan_defense/run_dual_defense_tests.py`）。

| 项 | .166 | .53 |
|----|------|-----|
| T1–T5 | PASS | PASS |

人手建议：开任意游戏前台 → 看假指纹/路径隐藏；写 bypass → 听 Toast；写 shutdown_trig → 恢复真机信息。

## 9. 防御分层（8-68 · 纠正「桌面隐藏」误区）

| 软件 | 实际能力 | 是否桌面隐藏 |
|------|----------|--------------|
| Shadow / FlyJB / Liberty / tsProtector | 目标 App 内绕过检测 | **否** |
| KernBypass / vnodebypass | 内核/vnode 藏路径 | **否**（副作用大，不采用） |
| Libhide 等 | 隐藏 SpringBoard 图标 | **是**（采纳思路） |

| 项 | 8-68 行为 |
|----|-----------|
| 第三方 App 伪装 | `ZiYanDefense`（指纹/路径 Hook） |
| 桌面图标 | `fscloakd` v8122 hide-once：开 App 边沿改名 `*.ziyan_desk_hidden` + uicache（禁每秒 ps） |
| 爱思/AFC | **零注入**；冷启还原 `*.ziyan_cloaked` 与桌面 App |
| `ZiYanFsCloak.dylib` | 空壳不注入 |

连爱思前请**重插 USB**。

## 10. 桌面越狱图标屏蔽（8-52 语义 · **8-122 hide-once**）

| 项 | 说明 |
|----|------|
| 模块 | `ZiYanIconShield.m`（ZiYanVol / SB）+ `ziyan_fscloakd.sh` v8122 |
| 隐藏 | 打开 ZiYan.app **边沿一次**（`.ziyan_icon_hide_req` + `.ziyan_app_session`） |
| 禁止 | App 心跳刷 hide_req；已隐藏态每秒 `ps`/`desk_hide`/`uicache`；IconShield 每拍进主队列（与找色抢 SB） |
| 保留 | **`com.ziyan.ziyan` 永不隐藏** |
| Home | **不恢复**（session 粘性；仅 `app_fg=0`） |
| 恢复 | 「关闭程序」· `applicationWillTerminate` · 冷启 `BootRecovery` · 无 session |
| 指纹 | 关 App **保持**假数据；冷启/断电 **清除**并下次重生 |
| 信息框 | 每次进程冷启动弹「防御伪装信息」（型号/系统/名称/IDFV/内外网 IP 等） |
| 音量 | CloseApp 后粘性 `vol_disarmed`，**禁止**凭 app_fg 误重武装 |

## 11. 编译

```bash
make package FINALPACKAGE=1
THEOS_PACKAGE_SCHEME=rootless make package FINALPACKAGE=1
```

产物含 `ZiYanDefense.dylib` + `ZiYanDefense.plist`。

---

## R8.4.1 · 脱壳自我进化（2026-07-27）

**来源**：`ZiYanDumpManager` 自动脱壳 → `ZYCV/res/dump_defense_feed.json`  
**检测手段（本地启发式 · 64KB 字符串分片）**：cydia/substrate/frida/ptrace/sysctl/FairPlay/codesign/iOSSecuritySuite 等  
**增强策略**：按 `risk_score` 写入 `defense_hints`（`hide_jb_paths` / `anti_debug_soften` / `deny_frida_port`）供 Defense 侧后续消费  
**约束**：禁止在 SpringBoard 解析整包 Mach-O；App 进程非 root 跳过容器拷贝防挂死  
**侧车**：`POST /v1/dump_analyze/run`（A/B/C 模型校验）→ 文件回退  
