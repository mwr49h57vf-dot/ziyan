# ZiYan 日志服务 v1（含本地自签 APT）

纯 Python3 标准库（+可选 `pgpy` 用于本地自签；缺 pgpy 时服务仍可跑，只是 `Release.gpg` 缺失并明确报错）。

## 启动

```bash
python3 tools/ziyan_log_server/server.py --port 18091 [--root ziyan_web_data] [--host 0.0.0.0]
```

## 端点一览

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | /api/logs | 上报错误日志（event_id 幂等） |
| GET | /api/logs?device=&type=&since=&until=&limit= | 列表+筛选 |
| GET | /api/logs/\<event_id> | 单条 |
| GET | /api/logs/download.zip | 打包下载（同筛选参数） |
| GET | /api/logs/export_desktop | 写入桌面 `ziyan错误日志/<时间戳>/` |
| POST | /api/hotupdate/publish | 发布热更新（包路径+兼容性字段） |
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
- 每次 publish 后自动刷新 dist；`Packages` 只收录文件真实存在的版本，
  并按 `iphoneos-arm / iphoneos-arm64` 分组。

## 验证记录（真实执行，摘要）

- `GET /apt/Release` → 200，含双架构 Packages 索引
- `GET /apt/Release.gpg` → 200（OpenPGP 二进制签名）
- `.101` 真实 gpg：import 公钥 → `gpg --verify Release.gpg Release` → Good signature
- `.101` 真实 apt-get（临时 source，LAN `http://192.168.31.81:18092/`）：读取 Release+Packages，
  `apt-cache policy/show` 正确显示候选版本与 SHA256；wget 下载 55MB deb 后 `dpkg-deb -f` 解析正常
- 公网 `apt.ziyan.com`：BLOCKED（无 DNS 记录）；`www.ziyan.com` 指向非本项目服务器，未触碰
