# ZiYan 测试迭代记录模板

> 每轮复制本模板生成 `tmp_shots/ITERATION_<时间>_<设备>/REPORT.md`。字段不得留空；不适用写N/A。

## 基本信息

- 开始/结束时间：
- 阶段和Gate：
- 测试设备：
- 对照设备及只读约束：
- 测试业务脚本及SHA256：
- 测试假设：
- 本轮唯一变量：

## 源码与构建

- 修改文件：
- 修改摘要：
- 包路径：
- 包SHA256：
- 二进制路径和SHA256：
- 签名/entitlement检查：
- `git diff --check`：

## 部署与回滚

- 部署前版本：
- 部署后版本：
- 部署目标：
- 设备备份路径：
- 是否重启App/SpringBoard/backboardd：
- 自动解锁结果：
- 回滚命令：

## 测试前真相源

- 真实前台bundle：
- 目标App进程/PID/RSS：
- framecap实例数/PID/RSS：
- SpringBoard PID/RSS：
- backboardd PID/RSS：
- 当前共享帧：seq/provider/status/front_hash/age：
- 标准点和预期颜色：

## 逐轮结果

| 轮次 | 场景 | 真实前台 | App PID | SB PID | seq/provider/status | 帧龄ms | 标准色 | find ms | Toast方向/位置 | 画面响应 | 判定 |
|---|---|---|---:|---:|---|---:|---|---:|---|---|---|
| 1 | App | | | | | | | | | | |
| 1 | Home | | | | | | | | | | |

## 性能统计

- find样本数：
- find正确/错误/误报：
- find P50/P95/max：
- 前台恢复 P50/P95/max：
- 帧龄 P50/P95/max：
- App RSS起点/终点/斜率：
- framecap RSS起点/终点/斜率：
- SpringBoard RSS起点/终点/斜率：
- CPU平均/P95/峰值：
- 每秒磁盘写入：
- 单飞冲突/超时次数：

## 稳定性和视觉检查

- Home键响应：
- App是否卡屏：
- 是否黑屏：
- 点击后画面是否继续更新：
- 锁屏/解锁恢复：
- Toast在App/Home/锁屏/解锁的位置：
- App/SB/backboardd/守护重启次数：
- Crash/Jetsam/SafeMode：
- 停止后残留：

## `.171` 同窗对照

- 允许的操作：只读采样及安全Home/最小化。
- 同时间窗：
- 找色/画面恢复：
- 卡屏/黑屏：
- Toast方向：
- RSS/CPU趋势：
- PID变化：
- 与ZiYan的可比差异：

## 结论

- `VERDICT=PASS/FAIL`：
- PASS满足了哪些门禁：
- FAIL的首个确定证据：
- 根因层级：截帧/epoch/缓存/find/触控/Toast/进程/构建/其他。
- 是否已回滚失败版本：
- 禁止宣称事项：
- 下一条唯一动作：

