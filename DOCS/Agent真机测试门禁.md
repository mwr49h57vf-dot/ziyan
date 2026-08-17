# Agent 真机测试门禁

设备：`.53/.101/.112/.166`。`.149/.171` 只读。

进入 AgentSmoke 前必须：新包已装、注入稳定、AUTO_UNLOCK_PASS、FC_N=1、zydaemon≥1。

`.101/.166` 必须先过 SB 环门禁。关闭注入不是 PASS。

Smoke：PRECHECK→…→STOPPED，动作一次，无登录支付聊天。敏感页 PAUSED_SAFE。

四机全过才允许 `AGENT_MVP_4PHONE_PASS=YES`。否则 PARTIAL/BLOCKED。
