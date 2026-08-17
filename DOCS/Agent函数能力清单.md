# Agent 函数能力清单

| 对象 | 本阶段 |
|---|---|
| GameProfile | JSON 字段齐，Smoke 只用 bundle + observe |
| DeviceOverlay | 每机独立，禁止共享绝对坐标 |
| AgentSession | IDLE…STOPPED/FAILED/PAUSED_SAFE |
| ActionContract | Smoke：`observe_front_once` |
| StateRecognizer | 前台 Bundle + frame_seq |
| DecisionEngine | 本地规则，无云 |
| RecoveryManager | 写报告，不重启 SB/BB |

禁止：任意 shell、下载执行、新守护、绕过 Session 的直接触控。
