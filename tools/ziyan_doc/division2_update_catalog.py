#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Division2: append new Zy.* entries to api_catalog.json."""
from __future__ import annotations

import datetime
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = Path(__file__).resolve().parent / "api_catalog.json"

NEW = [
    ("String", "trim", "去首尾空白", "Zy.String.trim(s)", "string", []),
    ("String", "split", "按分隔符切分", "Zy.String.split(str [, sep])", "table", [{"name": "str", "type": "string", "required": True}, {"name": "sep", "type": "string", "default": ","}]),
    ("String", "urlEncode", "URL 编码", "Zy.String.urlEncode(s)", "string", [{"name": "s", "type": "string", "required": True}]),
    ("String", "urlDecode", "URL 解码", "Zy.String.urlDecode(s)", "string", [{"name": "s", "type": "string", "required": True}]),
    ("String", "random", "随机字符串", "Zy.String.random(len [, charset])", "string", [{"name": "len", "type": "number", "default": 8}]),
    ("String", "intToRgb", "颜色整数转 RGB", "Zy.String.intToRgb(c)", "number,number,number", [{"name": "c", "type": "number", "required": True}]),
    ("String", "rgbToInt", "RGB 转颜色整数", "Zy.String.rgbToInt(r,g,b)", "number", []),
    ("Clipboard", "set", "写入剪贴板", "Zy.Clipboard.set(text)", "boolean", [{"name": "text", "type": "string", "required": True}]),
    ("Clipboard", "get", "读取剪贴板", "Zy.Clipboard.get()", "string", []),
    ("Clipboard", "clear", "清空剪贴板", "Zy.Clipboard.clear()", "boolean", []),
    ("Timer", "sleepMs", "毫秒延时", "Zy.Timer.sleepMs(ms)", "boolean", [{"name": "ms", "type": "number", "required": True}]),
    ("Timer", "sleep", "秒延时", "Zy.Timer.sleep(sec)", "boolean", [{"name": "sec", "type": "number", "required": True}]),
    ("Timer", "waitUntil", "轮询直到条件成立", "Zy.Timer.waitUntil(fn [, timeout_ms, interval_ms])", "boolean", [{"name": "fn", "type": "function", "required": True}]),
    ("Timer", "netTime", "网络时间戳", "Zy.Timer.netTime()", "number", []),
    ("Dialog", "alert", "提示框（toast 诚实实现）", "Zy.Dialog.alert(msg [, timeout_s])", "boolean", [{"name": "msg", "type": "string", "required": True}]),
    ("Dialog", "confirm", "双按钮对话框（诚实返回首按钮）", "Zy.Dialog.confirm(msg, btn1 [, btn2, timeout_s])", "number,string", []),
    ("Dialog", "input", "输入框（无模态时返回 default）", "Zy.Dialog.input(title [, default, timeout_s])", "boolean,string,string", []),
    ("File", "mkdir", "创建目录", "Zy.File.mkdir(path)", "boolean", [{"name": "path", "type": "string", "required": True}]),
    ("File", "list", "列出目录", "Zy.File.list(path)", "table", [{"name": "path", "type": "string", "required": True}]),
    ("File", "size", "文件大小字节", "Zy.File.size(path)", "number", [{"name": "path", "type": "string", "required": True}]),
    ("File", "copy", "复制文件/目录", "Zy.File.copy(src, dst)", "boolean", []),
    ("File", "move", "移动/重命名", "Zy.File.move(src, dst)", "boolean", []),
    ("File", "append", "追加写入", "Zy.File.append(path, content)", "boolean", []),
    ("Network", "setTimeout", "HTTP 默认超时秒", "Zy.Network.setTimeout(sec)", "number", [{"name": "sec", "type": "number", "required": True}]),
    ("Network", "download", "下载到本地", "Zy.Network.download(url, dest [, timeout])", "boolean,string", []),
    ("Network", "netIP", "本机 IP", "Zy.Network.netIP()", "string", []),
    ("Network", "netTime", "网络时间", "Zy.Network.netTime()", "number", []),
    ("Device", "isLocked", "是否锁屏", "Zy.Device.isLocked()", "boolean", []),
    ("Device", "batteryLevel", "电量 0-100", "Zy.Device.batteryLevel()", "number", []),
    ("Device", "osVersion", "系统版本", "Zy.Device.osVersion()", "string", []),
    ("Device", "ip", "局域网 IP", "Zy.Device.ip()", "string", []),
    ("Input", "setClipboard", "写剪贴板", "Zy.Input.setClipboard(text)", "boolean", []),
    ("Input", "getClipboard", "读剪贴板", "Zy.Input.getClipboard()", "string", []),
    ("Input", "keySequence", "顺序按键", "Zy.Input.keySequence(keys [, interval_ms])", "boolean", []),
    ("Input", "switchInputText", "切换子砚输入法（诚实失败）", "Zy.Input.switchInputText()", "boolean,string", []),
    # Division2 Wave2
    ("Network", "httpGet", "HTTP GET", "Zy.Network.httpGet(url [, timeout])", "boolean,string", [{"name": "url", "type": "string", "required": True}]),
    ("Network", "httpPost", "HTTP POST", "Zy.Network.httpPost(url, body [, timeout, headers])", "boolean,string", []),
    ("Network", "httpBuildQuery", "URL 参数字符串", "Zy.Network.httpBuildQuery(tbl)", "string", [{"name": "tbl", "type": "table", "required": True}]),
    ("File", "find", "按名查找路径", "Zy.File.find(pattern [, rootDir])", "table", []),
    ("File", "getFile", "读取文件（getFile 别名）", "Zy.File.getFile(path)", "string", []),
    ("File", "loadFile", "读取文件（loadFile 别名）", "Zy.File.loadFile(path)", "string", []),
    ("App", "bundlePath", "应用 Bundle 路径（best-effort）", "Zy.App.bundlePath(bid)", "string,string", []),
    ("App", "dataPath", "应用 Data 路径（best-effort）", "Zy.App.dataPath(bid)", "string,string", []),
    # Division2 Wave3
    ("Device", "osType", "系统类型", "Zy.Device.osType()", "string", []),
    ("Device", "deviceId", "设备 UUID", "Zy.Device.deviceId()", "string", []),
    ("Device", "deviceName", "设备名", "Zy.Device.deviceName()", "string", []),
    ("Device", "getAlias", "设备别名", "Zy.Device.getAlias()", "string", []),
    ("Device", "setAlias", "设置别名", "Zy.Device.setAlias(name)", "boolean", []),
    ("Device", "setDeviceName", "设置设备名", "Zy.Device.setDeviceName(name)", "boolean", []),
    ("Device", "memoryInfo", "内存 total/free/used", "Zy.Device.memoryInfo()", "table", []),
    ("Device", "netInterfaces", "网卡列表", "Zy.Device.netInterfaces()", "table", []),
    ("Device", "isAuth", "是否授权/越狱可用", "Zy.Device.isAuth()", "boolean", []),
    ("Device", "lock", "锁屏请求", "Zy.Device.lock()", "boolean", []),
    ("Device", "setWifiEnable", "WiFi 开关请求", "Zy.Device.setWifiEnable(on)", "boolean", []),
    ("Device", "connectToWifi", "连接 WiFi 请求", "Zy.Device.connectToWifi(ssid [, pass])", "boolean,string", []),
    ("Device", "setAutoLockTime", "自动锁屏秒数", "Zy.Device.setAutoLockTime(sec)", "boolean", []),
    ("Device", "setRotationLockEnable", "旋转锁", "Zy.Device.setRotationLockEnable(on)", "boolean", []),
    # Wave2 util docs
    ("Network", "jsonEncode", "JSON 编码（经 util）", "jsonEncode(tbl)", "string", []),
    ("Network", "jsonDecode", "JSON 解码（经 util）", "jsonDecode(str)", "any", []),
    # Division2 Wave4
    ("Thread", "create", "创建协作线程", "Zy.Thread.create(fn)", "number", []),
    ("Thread", "wait", "协作等待毫秒", "Zy.Thread.wait(ms)", "boolean", []),
    ("Thread", "setTimeout", "延时回调", "Zy.Thread.setTimeout(ms, fn)", "number", []),
    ("Thread", "clearTimeout", "取消延时", "Zy.Thread.clearTimeout(id)", "boolean", []),
    ("Thread", "stop", "停止协作线程", "Zy.Thread.stop(id)", "boolean", []),
    ("Thread", "waitAllThreadExit", "等待全部结束", "Zy.Thread.waitAllThreadExit([max])", "boolean", []),
    ("Widget", "isAccessibilityOn", "无障碍是否开启", "Zy.Widget.isAccessibilityOn()", "boolean", []),
    ("Widget", "find", "OCR 找控件文案", "Zy.Widget.find(text)", "boolean,number,number", []),
    ("Widget", "click", "点击控件/坐标", "Zy.Widget.click([text|x,y])", "boolean", []),
    ("Widget", "longClick", "长按", "Zy.Widget.longClick(...)", "boolean", []),
    ("Widget", "scrollForward", "上滑", "Zy.Widget.scrollForward()", "boolean", []),
    ("Widget", "scrollBackward", "下滑", "Zy.Widget.scrollBackward()", "boolean", []),
    ("Widget", "setText", "输入文本", "Zy.Widget.setText(text)", "boolean", []),
    ("File", "zip", "打包 zip", "Zy.File.zip(src, dst)", "boolean", []),
    ("File", "unzip", "解压 zip", "Zy.File.unzip(src [, dst])", "boolean", []),
]


def main() -> None:
    cat = json.loads(CATALOG.read_text(encoding="utf-8"))
    funcs = cat.setdefault("functions", {})
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    added = 0
    for mod, fn, summary, usage, ret, params in NEW:
        fid = f"Zy.{mod}.{fn}"
        if fid in funcs:
            continue
        funcs[fid] = {
            "id": fid,
            "name": fid,
            "module": mod,
            "summary": summary,
            "purpose": f"Division2 自研 {mod} 辅助 API",
            "params": params,
            "returns": {"type": ret, "desc": summary},
            "errors": ["无底层能力时诚实返回 false/-1"],
            "usage": usage,
            "example": f"local r = {usage.split('(')[0]}()",
            "principle": "Device→Screen→Coordinate→Vision→Touch→Verify→StateMachine",
            "status": "active",
            "updated": now,
            "changelog": ["division2-wave2"],
            "division2": True,
        }
        added += 1
    cat["division2_updated"] = now
    CATALOG.write_text(json.dumps(cat, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"catalog: added={added} total={len(funcs)}")


if __name__ == "__main__":
    main()
