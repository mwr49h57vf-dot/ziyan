# .171 对齐自测结果与下一步

日期：2026-08-10

## 本轮自测

命令：`ZY_LIVE_ROUNDS=3 ZY_LIVE_HOME_WAIT=6 ZY_LIVE_APP_WAIT=8 bash tools/zy_live_min_compare.sh`

原始证据：[LIVE_MIN_COMPARE_20260810_093232](/Users/mac/Desktop/ZiYan_副本/tmp_shots/LIVE_MIN_COMPARE_20260810_093232)

结论：`OVERALL=FAIL`

- HTTP timeout：9
- OPEN_FAIL：1（.112 第 3 轮）
- stale samples：4
- `.101`：App 前台帧龄约 19–22 秒，provider=UICreate，session=idle。
- `.112`：`black_backoff_keep`、`relay_seq`、`relay_timeout`；find 观察到 17–37 秒旧帧。
- `.166`：本轮 HTTP status 多次 timeout；远端状态无法形成稳定同口径证据。
- `.171` 只读进程采样：TSDaemon RSS 约 30208 KB，CPU 约 10.5–21.1%；本轮未写入、未部署、未修改。

这证明此前 `.112` 的 3 轮 settled 短门禁 PASS 不能代表三机长稳，更不能代表与 `.171` 对齐。

## 下一步（按顺序）

1. **冻结现有局部补丁**：不再继续添加 Home/Toast/relay 补刀；保留当前证据与回滚点。
2. **实现 FrameLeaseState**：`active → suspended → reacquiring → active`，前台/锁屏切换立即废弃旧 lease。
3. **收敛单一帧生产者**：业务 find 热路径只读取已提交的 resident IOSurface/IOMFB lease；禁止同步等待 SB relay、CARender、UICreate 子进程。
4. **失败语义改为不可用**：捕获失败返回 `reacquiring/unavailable`，不续用 stale/black/旧帧，不触发重复 fork。
5. **加入对齐仪表盘**：每 250ms 记录 `front、shm_bid、seq、age、provider、lease_state、black、relay_error、CPU、RSS、重启`，`.171` 只读采样使用同字段子集。
6. **先跑 10 分钟定位窗**：任一 `relay_timeout/relay_sb_fail/uicreate_exc/seq=0 持续/age>1200ms` 即 FAIL。
7. **再跑 30 分钟和 3 小时**：三机与 `.171` 同表比较；没有全绿前不进入下一阶段、不宣称完成。

## 当前禁止

- 不升级 `.166` 的 C-65.11 UICreate。
- 不部署或修改 `.53/.149/.171`。
- 不把短门禁 PASS 写成长期稳定。
