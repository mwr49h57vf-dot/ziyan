# 子砚通用自动化引擎（函数模块层）

**定位：** 通用自动化控制系统。游戏仅为验证环境。  
**版本：** modules 1.1.0 · engine 2.17.0  

## 架构

```
核心引擎层 (ziyan_engine)
    ↓
函数模块层 (Zy.*)
    ↓
脚本开发层 (Zy.Script / Zy.Engine)
    ↓
应用验证层（任意 Bundle 测试案例）
```

## 管道

`Device → Screen → Coordinate → Vision → OCR → Touch → Verify → StateMachine`

## 模块

| 模块 | 职责 |
|------|------|
| App | 启动/关闭/前后台/窗口状态/监控 |
| Device | 设备画像 |
| Screen | 屏幕同步 |
| Coordinate | 设计/比例映射 |
| Image / OCR / Vision | 视觉识别 |
| Touch | 设计/比例/命中点击 |
| Verify | 结果验证 |
| StateMachine | 通用状态机 |
| Game | **交互状态引擎**（非游戏专用） |
| Diagnose | 卡住时归因优化模块 |
| Case | 测试案例库 |
| Engine | 通用验证编排 |
| Script | 脚本会话 |

## 交互状态

`boot → loading → login → menu → role → running → error`

## 验证脚本

`_zy_engine_validate.lua`：只传 Bundle + 设计分辨率，不跑专用游戏流程。

测试 Bundle（案例库元数据）：`com.ljzbbadao.game` / `com.xztl.ios`
