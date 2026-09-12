# ZiYan 日志服务 v1（含本地自签 APT）

纯 Python3 标准库（+可选 `pgpy` 用于本地自签；缺 pgpy 时服务仍可跑，只是 `Release.gpg` 缺失并明确报错）。

## 启动

```bash
python3 tools/ziyan_log_server/server.py --port 18091 --root ziyan_web_data
```

默认监听 `127.0.0.1`。局域网分发需显式加 `--host 0.0.0.0 --allow-lan`。
同一数据目录只允许一个服务进程。启动时会恢复已写入事务记录的日志。

发布功能默认关闭。启用时指定 `--import-root <安装包导入目录>` 和
`--admin-token-file <管理员凭证文件>`。凭证至少 24 个字符，文件只保存一行。
设备上报可选 `--log-token-file <设备凭证文件>`，其值必须与管理员凭证不同。
凭证轮换后重启服务。管理页面输入新凭证并点击「验证授权」，随后选择导入目录中的包。
页面仅在当前输入框保留凭证，关闭页面或点击「清除凭证」后需要重新输入。

调用端使用 `Authorization: Bearer <凭证>`。发布缺少凭证返回 401，错误或权限不足返回 403，
服务未配置发布凭证返回 503。包下载和清单仍公开。远程管理应使用受信任的 HTTPS 入口。
导入仅接受真实 ZiYan deb，校验 Package、Version、Architecture、firmware 下限及管理员声明的兼容范围。
相同版本、架构和渠道再次发布相同内容会返回原记录，不同内容返回 409。
正常更新只选择严格更高的 Debian 版本；客户端在安装前再次查询真实已装版本。

热更新首次升级前，须为当前已装版本提供可读的旧包。可以把它放在
`<hotupdate_root>/versions/<当前版本>/package.deb`，或在 `HotUpdate.run_once` 的
选项中传入 `rollback_path`。模块会校验包控制信息、数据归档和 SHA256。
状态统一保存在原子替换的 `state` 文件中，读取旧的 `current`/`previous` 记录仅用于迁移。
检测到未完成的 `transaction` 时拒绝新安装。调用 `HotUpdate.rollback()` 执行并核验恢复。
调用方必须提供 `health_check(version)` 检查应用运行状态，返回 `true` 才能提交新状态。
缺少回调时返回 `false, "runtime_health_required"`，不会开始安装。
`run_once` 的 `dry_run` 和 `verify_only` 仅做检查或下载校验，可不传该回调。
包安装状态和准确版本始终为必查项。业务探测回调必须查询实际运行状态，不得以固定 `true` 代替。
当前仓库未发现生产调用方直接启用 `install` 或 `run_once`；接入设备自动更新时需先接好受控健康探测。

## 端点一览

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | /api/logs | 上报错误日志（event_id 幂等） |
| GET | /api/logs?device=&type=&since=&until=&limit= | 列表+筛选 |
| GET | /api/logs/\<event_id> | 单条 |
| GET | /api/logs/download.zip | 打包下载（同筛选参数） |
| GET | /api/logs/export_desktop | 写入桌面 `ziyan错误日志/<时间戳>/` |
| GET | /api/admin/session | 验证发布管理员凭证 |
| POST | /api/hotupdate/publish | 管理员发布热更新（导入目录内的真实包及兼容范围） |
| GET | /api/hotupdate/check?... | 兼容性判定（多架构回退选择） |
| GET | /hotupdate/manifest.json | 当前清单 |
| GET | /hotupdate/packages/... | 静态包下载（支持 Range） |
| GET | /apt/Release、/apt/Release.gpg、/apt/ziyan-apt-key.asc | **本地自签 APT**（见下） |
| GET | /apt/dists/stable/main/binary-\<arch>/Packages | 按架构的包索引 |
| GET | /apt/dists/stable/pool/\<version>/\<file> | deb 实体 |
| GET | / | HTML 管理页 |

## 本地自签 APT（重要说明）

- 密钥在首次启动含 APT 的请求时自动生成并落盘：
  `tools/ziyan_log_server/.apt_signing_key.asc`（600 权限）、`.apt_signing_pub.asc`。
- `Release.gpg` 是该密钥对当前 `Release` 的 **detached OpenPGP 签名**，
  已用 `.101` 真实 `gpg 2.2.11` 验证：`Good signature from "ZiYan APT (local self-signed)"`。
- **明确为本地自签测试密钥，不是官方发布密钥**；`/apt/InRelease` 返回说明文本而非 GPG clearsign。
- 请求 APT 元数据时刷新 dist；`Packages` 只收录文件真实存在的版本，
  并按 `iphoneos-arm / iphoneos-arm64` 分组。

## 历史设备验证记录（本轮未重跑）

- `GET /apt/Release` → 200，含双架构 Packages 索引
- `GET /apt/Release.gpg` → 200（OpenPGP 二进制签名）
- `.101` 真实 gpg：import 公钥 → `gpg --verify Release.gpg Release` → Good signature
- `.101` 真实 apt-get（临时 source，LAN `http://192.168.31.81:18092/`）：读取 Release+Packages，
  `apt-cache policy/show` 正确显示候选版本与 SHA256；wget 下载 55MB deb 后 `dpkg-deb -f` 解析正常
- 公网 `apt.ziyan.com`：BLOCKED（无 DNS 记录）；`www.ziyan.com` 指向非本项目服务器，未触碰
