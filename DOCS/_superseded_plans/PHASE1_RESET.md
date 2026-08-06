# Phase1-R · 过程优先（8-161-115）

## 原则

先审计过程证据 → 再改 → 硬门禁自测全绿 → 才人工测。禁跳结论叠补丁。

## 为何触动稳、我们曾炸

| 触动 Pe | 子砚过程坑 |
|---------|-----------|
| 单宿主 TSDaemon | soft/粘性旗假保活 |
| 升级不毁脚本 | 旧 prerm 升级 `rm -rf` |
| 窄 ROI 锚点在区内 | pad 外溢假「登录」 |
| 抓色器代码怎么写怎么跑 | findtest 空帧过早 empty_shm；业务 if 与找色未同门禁 |

## 8-161-115 抓色器 ↔ 业务

1. **formats.py** ≡ ColorPicker `make_FMC` ≡ Desktop `ios7.lua` / `ios8p.lua` 色串  
2. **ColorMatch** + findtest/embed：`ok=true` ⇒ 锚点在原始 ROI（pad 只扩搜索）  
3. **`POST /biztest`**：仿真 `if FIND1.x~=-1 then tap elseif FIND2 then 登录 else searching`  
4. **embed** 返回坐标再校验 ROI，与 `if x~=-1` 一致  
5. **findtest**：CARender 黑屏后再等 ServeLoop 合帧（禁假 empty_shm）

## 门禁（全绿才人工测）

| 脚本 | 含义 |
|------|------|
| `tools/p1r_picker_biz_gate_4phone.sh` | 抓色器↔业务分支 |
| `tools/p1r_gate_4phone.sh` | 会话/升级/ROI |
| `tools/p1r_cpu_gate_4phone.sh` | 冷闲 CPU/RSS/shm |

## 版本链

- 111：ROI 锚点 + toast UTF-8  
- 112：prerm 安全 + session 基线  
- 113–114：冷闲 CPU/释帧  
- **115：/biztest + ok⇒in_orig 双保险 + findtest 合帧等待**
- **116：.53 现场 — 同色竖条防壁纸假「登录」；音量 toast「已启动」；软杀竞态**

## 人工测（音量键「运行」）

- `.53`：`ios8p.lua`  
- `.101/.112/.166`：`ios7.lua`  
- 禁止 SSH 代启脚本当验收  
