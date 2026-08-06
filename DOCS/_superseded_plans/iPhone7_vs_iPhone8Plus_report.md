# iPhone7 vs iPhone8 Plus — 坐标全链路对比（7.6.3-R3）

**日期**：2026-07-23  
**设备**：`.166` iPhone7 / iOS13.1.2 / rootful · `.53` iPhone8 Plus / iOS16.7.16 / rootless  
**约束**：无单设备坐标特判；tap 底层未改  

---

## 1. 屏幕 / 缓冲

| 项 | .166 | .53 |
|----|------|-----|
| native | 640×1136 @2 | 1242×2208 @3 |
| logicBuf(init1) | 1136×640 | **2208×1242**（非错误 1920×1080） |
| 单帧 RGBA | ≈2.9MB | ≈11.0MB（≈3.77×） |
| R3 后 capture | **cap=0**（旋转后丢弃竖屏缓冲） | **cap=0** |
| UIScreen raw（游戏横屏） | 568×320 | 736×414 |

## 2. CoordinateSpace（统一）

`Capture → OrientMap → logicBuf → Vision(x,y) → tap 原样 → Overlay(ScreenTransform)`  

双机：`transform_count=1` · `x1=x2=x3` · 横屏窗 AppTouch `identity`  

## 3. Overlay / Toast（R3 后现场）

| | .166 | .53 |
|--|------|-----|
| 会话中横屏 | `rawLand_identity host=568x320 rot=0` | `rawLand_identity host=736x414 rot=0` |
| 空闲 | uiOrient=0 竖屏（废除 180s 伪会话） | 同规则 |

角点 mapping：双机 **5/5 err=ok**

## 4. 根因差异（为何 .53 更「异常」）

1. 缓冲体积更大 → jetsam 更易  
2. rootless + iOS16 场景/合成差异 → raw 竖/横翻转更频繁  
3. 旧逻辑 180s orient 伪会话 → 空闲 Overlay 错向（R3 已废）  

**非** Retina scale 算错成 1080p。

## 5. Volume 状态机（R3）

- 空闲 / 无会话：`uiOrient=0` 竖屏  
- 脚本会话：跟 `.ziyan_orient` + `ZiYanScreenTransform`  
- 停脚本：清 `script_session` / `project_active` → 回竖屏  

## 6. 证据

`tmp_shots/PHASE763R3_FIX/verify_*.txt` · `logs/screen_mirror/` · `device_difference_report.md`
