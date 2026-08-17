---
name: ziyan-legacy-skill-redirect
description: Legacy redirect for the ZiYan project. Use the project-local ziyan-verdict-loop skill and ROADMAP.md instead.
alwaysApply: false
---

# 已迁移

此文件不再包含执行规则。对 ZiYan 的开发、部署、真机验收或进度续作，使用：

`$ziyan-verdict-loop`

权威门禁仍是仓库根目录的 `ROADMAP.md`。旧文件中的 iOS 17 范围、三小时门禁、全量逆向和大范围重构要求均已作废，不得执行。

部署默认只安装并读取状态。禁止生成或执行 `dpkg -i && killall SpringBoard` / `sbreload` / `ldrestart`。重载注入必须由用户明确授权后作为独立步骤进行。
