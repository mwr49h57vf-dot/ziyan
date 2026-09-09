# Lua Offline Compatibility Matrix

Scope: offline loading and action compatibility contracts only. This matrix
records API shapes observed during static review without copying business
source, private network endpoints, credentials, or coordinates.

| API shape | Status | Contract |
| --- | --- | --- |
| `require("ts")` | Implemented | Returns ZiYan-owned offline `ts` table and exposes `_G.ts`. |
| `require("sz")` | Implemented | Returns ZiYan-owned offline `sz` table and exposes `_G.sz`. |
| `require("TSLib")` | Implemented | Loads the two tables and installs the offline `init` entrypoint. |
| `init(...)` | Implemented | Stores only `{ bid, orient, mode = "offline" }` in memory; no device, network, or process call. |
| `sz.json.encode/decode` | Implemented | Maps directly to ZiYan's local `json.lua`. |
| `ts.config.open/get/save/delete/close` | Implemented | Uses a handle-backed in-memory namespace with explicit `open`/`closed` state and stable `closed_handle` errors. |
| `ts.config.load/read/write/set/path/root` | Compatibility only | Legacy aliases over the same allowlisted in-memory store; no caller-selected filesystem path. |
| `ts`, `sz`, and `init` global aliases | Compatibility only | Aliases support legacy lookup after `require("TSLib")`; they do not add device behavior. |
| `findColor`, `findColorFuzzy`, `findColorInRegion`, `findColorInRegionFuzzy`, `findMultiColor`, `findMultiColorInRegionFuzzy` | Offline stub | Valid parameters return `-1, -1, "unsupported:offline_vision"`; invalid parameters return `false, "invalid:offline_vision_args"`. No screenshot, CV, OCR, or screen access. |
| `touchDown`, `touchMove`, `touchUp`, `tap` | Offline stub | Valid parameters return `false, "unsupported:offline_touch"`; invalid parameters return `false, "invalid:offline_touch_args"`. No HID, BBTouch, BackBoard, or injection path. |
| `runApp`, `openApp`, `closeApp`, `appRunning`, `appRun`, `appKill`, `appIsRunning` | Offline stub | Valid bundle IDs return `false, "unsupported:offline_app"`; invalid bundle IDs return `false, "invalid:offline_app_args"`. No launch, stop, foreground switch, or real app query. |
| Real visual recognition / hit coordinates | Explicitly rejected | The offline contract has no image source and never reads screenshots or invokes CV/OCR. |
| Real touch injection / gesture delivery | Explicitly rejected | The offline contract never writes touch requests and never calls HID, BBTouch, BackBoard, or device bridges. |
| Real app lifecycle / foreground state | Explicitly rejected | The offline contract never starts, stops, switches, or queries an application. |
| Device-backed vision, touch, and app behavior | Pending device validation | Requires a separately approved real-device contract and validation; this stage supplies stubs only. |
| `readFile*`, `writeFile*`, file listing/mutation | To implement | Static observation only; broader file APIs need a separate allowlisted contract. |
| `ts.ftp.*` | Explicitly rejected | Every known FTP operation returns `false, "unsupported:offline_ftp"` and never stores or uses arguments. |
| Arbitrary `ZIYAN_COMPAT_CONFIG_DIR` / `ZIYAN_VAR` | Explicitly rejected | Only the declared ZiYan config root and two declared ZiYan var roots are accepted; arbitrary absolute directories fail with `invalid_config_root`. |
| `..`, NUL, newline, nested path, non-TouchSprite absolute path | Explicitly rejected | Config names are single allowlisted names; legacy absolute paths map only from the exact TouchSprite config prefix to a namespace name. |
| `os.execute`, root shell, implicit remote update/download | Explicitly rejected | The compatibility modules do not expose or call these capabilities. |
