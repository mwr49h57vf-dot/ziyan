# probes/

本地真机/取色探测产物目录，**不参与 deb 打包**。

## 用途

- 从设备拉回的截图（`*.png` / `*.ppm`）
- 一次性探测脚本（`tmp_probe*.py`）

## 策略

- 临时图与 tmp 脚本可随时清空
- 请勿把长期真相源放在本目录；脚本 API 真相源在 `lua/`，装机用户脚本在 `layout/private/var/mobile/Media/ZiYan/`

```bash
# 清空探测产物（保留本 README）
find probes -type f ! -name 'README.md' -delete
```
