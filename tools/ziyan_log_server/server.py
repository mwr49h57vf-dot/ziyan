#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ZiYan 日志服务 v1（纯标准库）
契约：DOCS/接口契约_日志服务_v1.md（冻结 2026-09-11）
端口：默认 18091；ROOT 默认 /Users/mac/Desktop/ZiYan_副本/ziyan_web_data
运行：python3 tools/ziyan_log_server/server.py --port 18091 [--root <dir>] [--host 0.0.0.0]
"""
import argparse
import base64
import datetime
import hashlib
import io
import json
import mimetypes
import os
import re
import threading
import urllib.parse
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_ROOT = "/Users/mac/Desktop/ZiYan_副本/ziyan_web_data"
DEFAULT_PORT = 18091

ROOT = DEFAULT_ROOT
INDEX_LOCK = threading.Lock()
MANIFEST_LOCK = threading.Lock()
SERVER_DIR = os.path.dirname(os.path.abspath(__file__))

# ---------- 基础工具 ----------

def now_str():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

def today_str():
    return datetime.datetime.now().strftime("%Y-%m-%d")

def ensure_dirs():
    for d in (os.path.join(ROOT, "logs"),
              os.path.join(ROOT, "hotupdate", "packages"),
              os.path.join(ROOT, "apt")):
        os.makedirs(d, exist_ok=True)

def atomic_write_bytes(path, data: bytes):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp.%d.%d" % (os.getpid(), threading.get_ident() % 1000000)
    # 避免并发冲突：加上随机后缀
    import random
    tmp = "%s.tmp.%d.%d" % (path, os.getpid(), random.randint(0, 1 << 30))
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        try:
            os.fsync(f.fileno())
        except Exception:
            pass
    os.replace(tmp, path)

def atomic_write_text(path, text: str):
    atomic_write_bytes(path, text.encode("utf-8"))

def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def file_size(path: str) -> int:
    return os.path.getsize(path)

def index_path():
    return os.path.join(ROOT, "logs", "index.jsonl")

def manifest_path():
    return os.path.join(ROOT, "hotupdate", "manifest.json")

def packages_dir():
    return os.path.join(ROOT, "hotupdate", "packages")

def load_index_entries():
    p = index_path()
    entries = []
    if not os.path.exists(p):
        return entries
    try:
        with open(p, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entries.append(json.loads(line))
                except Exception:
                    continue
    except FileNotFoundError:
        return []
    return entries

def append_index_atomic(entry: dict):
    with INDEX_LOCK:
        entries = load_index_entries()
        entries.append(entry)
        lines = "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in entries)
        atomic_write_text(index_path(), lines)

def find_index_entry(event_id: str):
    for e in load_index_entries():
        if e.get("event_id") == event_id:
            return e
    return None

def event_file_for(event_id: str):
    # 先查索引
    e = find_index_entry(event_id)
    if e and e.get("path"):
        ap = os.path.join(ROOT, e["path"])
        if os.path.exists(ap):
            return ap
    # 兜底 glob logs/*/<id>.json
    base = os.path.join(ROOT, "logs")
    if not os.path.isdir(base):
        return None
    for date_dir in os.listdir(base):
        cand = os.path.join(base, date_dir, event_id + ".json")
        if os.path.isfile(cand):
            return cand
    return None

def extract_device_str(report: dict) -> str:
    d = report.get("device", "")
    if isinstance(d, dict):
        for k in ("model", "device", "name", "id"):
            v = d.get(k)
            if isinstance(v, str) and v.strip():
                return v
        # 兜底：拼接可读字段
        try:
            # 优先 model/os/arch 组合
            m = str(d.get("model", ""))
            if m:
                return m
            return json.dumps(d, ensure_ascii=False)[:200]
        except Exception:
            return ""
    if isinstance(d, str):
        return d
    if d is None:
        return ""
    return str(d)

def extract_script_str(report: dict) -> str:
    s = report.get("script", "")
    if isinstance(s, dict):
        for k in ("name", "path", "file", "script"):
            v = s.get(k)
            if isinstance(v, str) and v.strip():
                return v
        try:
            return json.dumps(s, ensure_ascii=False)[:300]
        except Exception:
            return ""
    if isinstance(s, str):
        return s
    if s is None:
        return ""
    return str(s)

def date_dir_for(report: dict, received_at: str) -> str:
    t = report.get("time", "")
    if isinstance(t, str) and re.match(r"^\d{4}-\d{2}-\d{2}", t):
        return t[:10]
    if isinstance(received_at, str) and re.match(r"^\d{4}-\d{2}-\d{2}", received_at):
        return received_at[:10]
    return today_str()

def parse_version_tuple(s: str):
    # "15.8.8"/"0.0.92-x"/"13.0" -> (15,8,8)
    if s is None:
        return ()
    s = str(s).strip()
    if not s:
        return ()
    parts = re.split(r"[.\-+_~]+", s)
    out = []
    for p in parts:
        m = re.match(r"^(\d+)", p)
        if m:
            out.append(int(m.group(1)))
        elif p.isdigit():
            out.append(int(p))
        else:
            # 非数字段停止？保留可比性：忽略
            continue
    return tuple(out)

def cmp_version(a: str, b: str) -> int:
    ta = parse_version_tuple(a)
    tb = parse_version_tuple(b)
    n = max(len(ta), len(tb))
    ta = ta + (0,) * (n - len(ta))
    tb = tb + (0,) * (n - len(tb))
    if ta < tb:
        return -1
    if ta > tb:
        return 1
    return 0

def version_ge(a: str, b: str) -> bool:
    return cmp_version(a, b) >= 0

def version_le(a: str, b: str) -> bool:
    return cmp_version(a, b) <= 0

def arch_match(pkg_arch: str, req_arch: str) -> bool:
    pa = (pkg_arch or "").strip().lower()
    ra = (req_arch or "").strip().lower()
    if not pa or not ra:
        return False
    if pa == ra:
        return True
    if pa == "iphoneos-arm64" and ra in ("arm64", "arm64e", "aarch64", "iphoneos-arm64"):
        return True
    if pa == "iphoneos-arm" and ra in ("arm", "armv7", "armv7s", "armv7k", "iphoneos-arm"):
        return True
    return False

SIGNING_KEY_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".apt_signing_key.asc")
SIGNING_PUB_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".apt_signing_pub.asc")
APT_SIGNING_NOTE = "local self-signed (NOT an official release key)"

def _apt_key():
    """加载或生成本地自签密钥（首次调用时生成并落盘，重启服务保持同一密钥）。"""
    try:
        import pgpy
        from pgpy.constants import PubKeyAlgorithm, KeyFlags, HashAlgorithm, SymmetricKeyAlgorithm, CompressionAlgorithm
    except Exception:
        return None, None
    if os.path.exists(SIGNING_KEY_FILE):
        try:
            key, _ = pgpy.PGPKey.from_file(SIGNING_KEY_FILE)
            return pgpy, key
        except Exception:
            pass
    key = pgpy.PGPKey.new(PubKeyAlgorithm.RSAEncryptOrSign, 2048)
    uid = pgpy.PGPUID.new("ZiYan APT", comment="local self-signed", email="apt@ziyan.local")
    key.add_uid(uid, usage={KeyFlags.Sign, KeyFlags.Certify},
                hashes=[HashAlgorithm.SHA256],
                ciphers=[SymmetricKeyAlgorithm.AES256],
                compression=[__import__("pgpy").constants.CompressionAlgorithm.ZLIB])
    with open(SIGNING_KEY_FILE, "w") as fh:
        fh.write(str(key))
    os.chmod(SIGNING_KEY_FILE, 0o600)
    with open(SIGNING_PUB_FILE, "w") as fh:
        fh.write(str(key.pubkey))
    return pgpy, key


def _detached_sig_b64(release_bytes):
    """返回 Release.gpg 的 base64（由本地自签密钥生成 detached OpenPGP 签名）。"""
    pgpy, key = _apt_key()
    if pgpy is None or key is None:
        return None
    from pgpy.constants import HashAlgorithm
    sig = key.sign(release_bytes, hash=HashAlgorithm.SHA256)
    return base64.b64encode(bytes(sig)).decode("ascii")


def _apt_dist_dir():
    d = os.path.join(ROOT, "apt_dists", "stable")
    os.makedirs(d, exist_ok=True)
    return d


def refresh_apt_dist():
    """把仓库内容同步为 apt dist（Packages + Release + Release.gpg + InRelease 占位）。"""
    d = _apt_dist_dir()
    man = load_manifest()
    vers = man.get("versions", [])
    # 按架构分组写 Packages（只收录真实存在的文件）
    by_arch = {}
    for v in vers:
        url = v.get("url", "")
        if not url.startswith("/hotupdate/packages/"):
            continue
        rel = url[len("/hotupdate/packages/"):]
        src = os.path.join(ROOT, "hotupdate", "packages", rel)
        if not os.path.isfile(src):
            continue
        arch = v.get("architecture", "")
        by_arch.setdefault(arch, []).append((v, rel, src))
    index_lines = ["Origin: ZiYan", "Label: ZiYan", "Suite: stable", "Codename: stable",
                   "Architectures: " + " ".join(sorted(by_arch)) if by_arch else "Architectures: ",
                   "Components: main",
                   "Description: ZiYan automation engine (LAN test repo, self-signed)",
                   "Date: " + now_str()]
    for arch in sorted(by_arch):
        pdir = os.path.join(d, "main", "binary-" + arch)
        os.makedirs(pdir, exist_ok=True)
        lines = []
        for v, rel, src in by_arch[arch]:
            lines.append("Package: com.ziyan.ziyan")
            lines.append("Version: " + v.get("version", ""))
            lines.append("Architecture: " + arch)
            lines.append("Maintainer: ZiYan")
            lines.append("Depends: firmware (>= 13.0), ellekit | mobilesubstrate")
            lines.append("Section: Utilities")
            lines.append("Filename: pool/" + rel)
            lines.append("Size: " + str(int(v.get("size", 0))))
            if v.get("sha256"):
                lines.append("SHA256: " + v["sha256"])
            lines.append("Description: ZiYan automation (self-signed test repo)")
            lines.append("")
        pkg_body = "\n".join(lines)
        with open(os.path.join(pdir, "Packages"), "w") as fh:
            fh.write(pkg_body)
        index_lines.append("SHA256-Packages-%s: %s %d" % (
            arch, hashlib.sha256(pkg_body.encode()).hexdigest(), len(pkg_body.encode())))
    release_body = "\n".join(index_lines) + "\n"
    with open(os.path.join(d, "Release"), "w") as fh:
        fh.write(release_body)
    b64 = _detached_sig_b64(release_body.encode("utf-8"))
    if b64:
        with open(os.path.join(d, "Release.gpg.b64"), "w") as fh:
            fh.write(b64 + "\n")
        raw = base64.b64decode(b64)
        with open(os.path.join(d, "Release.gpg"), "wb") as fh:
            fh.write(raw)
    else:
        with open(os.path.join(d, "Release.gpg.missing"), "w") as fh:
            fh.write("pgpy unavailable\n")
    return d


def load_manifest():
    p = manifest_path()
    if not os.path.exists(p):
        return {"versions": [], "channels": {}, "updated_at": ""}
    try:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return {"versions": [], "channels": {}, "updated_at": ""}
        data.setdefault("versions", [])
        data.setdefault("channels", {})
        data.setdefault("updated_at", "")
        return data
    except Exception:
        return {"versions": [], "channels": {}, "updated_at": ""}

def save_manifest_atomic(data: dict):
    with MANIFEST_LOCK:
        data["updated_at"] = now_str()
        text = json.dumps(data, ensure_ascii=False, indent=2)
        atomic_write_text(manifest_path(), text)

def load_event_json(path: str):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None

# ---------- HTTP Handler ----------

class Handler(BaseHTTPRequestHandler):
    server_version = "ZiYanLogServer/1.0"

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args))

    # -- 发送 helpers --
    def _send_json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _send_bytes(self, data: bytes, ctype: str, status=200, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self, limit=300 * 1024 * 1024):
        ln = self.headers.get("Content-Length")
        if ln is None:
            return b""
        try:
            n = int(ln)
        except Exception:
            return b""
        if n < 0 or n > limit:
            return b""
        if n == 0:
            return b""
        return self.rfile.read(n)

    # -- 路由 --
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = urllib.parse.unquote(parsed.path)
        qs = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        try:
            if path == "/":
                return self.handle_root()
            if path == "/api/logs/download.zip":
                return self.handle_logs_download(qs)
            if path == "/api/logs/export_desktop":
                return self.handle_logs_export_desktop(qs)
            if path == "/api/logs" or path == "/api/logs/":
                return self.handle_logs_list(qs)
            if path.startswith("/api/logs/"):
                eid = path[len("/api/logs/"):]
                # 禁止多余斜杠
                if "/" in eid or not eid:
                    return self._send_json({"ok": False, "error": "not_found"}, 404)
                return self.handle_logs_one(urllib.parse.unquote(eid))
            if path == "/api/hotupdate/check":
                return self.handle_hotupdate_check(qs)
            if path == "/hotupdate/manifest.json":
                return self.handle_manifest()
            if path == "/apt/Release" or path == "/apt/dists/stable/Release":
                return self.handle_apt_file("Release")
            if path == "/apt/Release.gpg" or path == "/apt/dists/stable/Release.gpg":
                return self.handle_apt_file("Release.gpg")
            if path == "/apt/InRelease" or path == "/apt/dists/stable/InRelease":
                return self.handle_apt_file("InRelease")
            if path == "/apt/ziyan-apt-key.asc" or path == "/apt/dists/stable/ziyan-apt-key.asc":
                return self.handle_apt_file("ziyan-apt-key.asc")
            if path.startswith("/apt/pool/") or path.startswith("/apt/dists/stable/pool/"):
                base = "/apt/dists/stable/pool/" if path.startswith("/apt/dists/stable/pool/") else "/apt/pool/"
                return self.handle_apt_pool(path[len(base):])
            if path.startswith("/apt/") and path.endswith("/Packages"):
                return self.handle_apt_packages(path)
            if path.startswith("/hotupdate/packages/"):
                rel = path[len("/hotupdate/packages/"):]
                return self.handle_package_file(rel)
            return self._send_json({"ok": False, "error": "not_found"}, 404)
        except BrokenPipeError:
            pass
        except Exception as e:
            try:
                self._send_json({"ok": False, "error": "internal: %s" % e}, 500)
            except Exception:
                pass

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = urllib.parse.unquote(parsed.path)
        try:
            if path == "/api/logs":
                return self.handle_logs_post()
            if path == "/api/hotupdate/publish":
                return self.handle_hotupdate_publish()
            return self._send_json({"ok": False, "error": "not_found"}, 404)
        except BrokenPipeError:
            pass
        except Exception as e:
            try:
                self._send_json({"ok": False, "error": "internal: %s" % e}, 500)
            except Exception:
                pass

    def do_HEAD(self):
        # 对静态包支持 HEAD（Range 语义同 GET 但无 body）
        parsed = urllib.parse.urlparse(self.path)
        path = urllib.parse.unquote(parsed.path)
        if path.startswith("/hotupdate/packages/"):
            rel = path[len("/hotupdate/packages/"):]
            return self.handle_package_file(rel, head_only=True)
        self.send_response(405)
        self.send_header("Content-Length", "0")
        self.end_headers()

    # -- 1. POST /api/logs --
    def handle_logs_post(self):
        raw = self._read_body()
        if not raw:
            return self._send_json({"ok": False, "error": "empty_body"}, 400)
        try:
            report = json.loads(raw.decode("utf-8"))
        except Exception:
            return self._send_json({"ok": False, "error": "invalid_json"}, 400)
        if not isinstance(report, dict):
            return self._send_json({"ok": False, "error": "invalid_json"}, 400)
        event_id = report.get("event_id", "")
        if not isinstance(event_id, str) or not event_id.strip():
            return self._send_json({"ok": False, "error": "missing_event_id"}, 400)
        event_id = event_id.strip()
        # 安全：event_id 只允许常见字符，防止路径穿越
        if not re.match(r"^[A-Za-z0-9_\-\.]+$", event_id):
            return self._send_json({"ok": False, "error": "bad_event_id"}, 400)
        # 幂等
        exist = event_file_for(event_id)
        if exist is not None:
            old_entry = find_index_entry(event_id)
            stored = old_entry.get("path") if old_entry and old_entry.get("path") else os.path.relpath(exist, ROOT)
            return self._send_json({"ok": True, "dedup": True, "event_id": event_id, "stored": stored}, 200)
        received_at = now_str()
        date_dir = date_dir_for(report, received_at)
        rel_path = "logs/%s/%s.json" % (date_dir, event_id)
        abs_path = os.path.join(ROOT, rel_path)
        # 原子写盘：规范化 JSON（与设备 report.json 同构）
        canonical = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=False)
        data_bytes = (canonical + "\n").encode("utf-8")
        atomic_write_bytes(abs_path, data_bytes)
        digest = sha256_bytes(data_bytes)
        entry = {
            "event_id": event_id,
            "device": extract_device_str(report),
            "time": str(report.get("time", "")),
            "type": str(report.get("type", "")),
            "path": rel_path,
            "sha256": digest,
            "received_at": received_at,
        }
        # 二次幂等（并发）：若索引已存在则视为 dedup
        with INDEX_LOCK:
            cur = load_index_entries()
            for e in cur:
                if e.get("event_id") == event_id:
                    return self._send_json({"ok": True, "dedup": True, "event_id": event_id, "stored": e.get("path", rel_path)}, 200)
            cur.append(entry)
            lines = "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in cur)
            atomic_write_text(index_path(), lines)
        return self._send_json({"ok": True, "dedup": False, "event_id": event_id, "stored": rel_path}, 200)

    # -- 过滤公共逻辑 --
    def _filtered_records(self, qs, apply_limit=True, for_download=False):
        def q(name):
            v = qs.get(name, [""])[0]
            return v.strip() if isinstance(v, str) else ""
        f_device = q("device")
        f_type = q("type")
        f_since = q("since")
        f_until = q("until")
        f_limit = q("limit")
        entries = load_index_entries()
        # 最新在前
        entries = list(reversed(entries))
        records = []
        for e in entries:
            rel = e.get("path", "")
            ap = os.path.join(ROOT, rel) if rel else None
            rep = load_event_json(ap) if ap and os.path.exists(ap) else None
            if rep is None:
                # 索引孤儿：用索引字段兜底
                rec = {
                    "event_id": e.get("event_id", ""),
                    "device": e.get("device", ""),
                    "device_raw": e.get("device", ""),
                    "time": e.get("time", ""),
                    "time_unix": None,
                    "type": e.get("type", ""),
                    "script": "",
                    "message": "",
                    "_path": rel,
                    "_report": None,
                }
            else:
                rec = {
                    "event_id": rep.get("event_id", e.get("event_id", "")),
                    "device": extract_device_str(rep),
                    "device_raw": rep.get("device", ""),
                    "time": str(rep.get("time", e.get("time", ""))),
                    "time_unix": rep.get("time_unix"),
                    "type": str(rep.get("type", e.get("type", ""))),
                    "script": extract_script_str(rep),
                    "message": str(rep.get("message", "")),
                    "_path": rel,
                    "_report": rep,
                }
            # device 筛选：子串（大小写不敏感），同时匹配序列化 device
            if f_device:
                hay1 = (rec["device"] or "").lower()
                try:
                    hay2 = json.dumps(rec["device_raw"], ensure_ascii=False).lower()
                except Exception:
                    hay2 = str(rec["device_raw"]).lower()
                if f_device.lower() not in hay1 and f_device.lower() not in hay2:
                    continue
            if f_type and rec["type"] != f_type:
                continue
            if f_since:
                if re.match(r"^\d+$", f_since):
                    try:
                        tu = rec.get("time_unix")
                        if tu is None or int(tu) < int(f_since):
                            continue
                    except Exception:
                        continue
                else:
                    if (rec.get("time", "") or "") < f_since:
                        continue
            if f_until:
                if re.match(r"^\d+$", f_until):
                    try:
                        tu = rec.get("time_unix")
                        if tu is None or int(tu) > int(f_until):
                            continue
                    except Exception:
                        continue
                else:
                    if (rec.get("time", "") or "") > f_until:
                        continue
            records.append(rec)
        total = len(records)
        if apply_limit and not for_download:
            lim = 200
            if f_limit:
                try:
                    lim = int(f_limit)
                except Exception:
                    lim = 200
                if lim <= 0:
                    lim = 200
                if lim > 2000:
                    lim = 2000
            records = records[:lim]
        elif apply_limit and for_download and f_limit:
            try:
                lim = int(f_limit)
                if lim > 0:
                    records = records[:min(lim, 10000)]
            except Exception:
                pass
        return total, records

    # -- 2. GET /api/logs --
    def handle_logs_list(self, qs):
        total, records = self._filtered_records(qs, apply_limit=True)
        items = []
        for r in records:
            items.append({
                "event_id": r["event_id"],
                "device": r["device"],
                "time": r["time"],
                "type": r["type"],
                "script": r["script"],
                "message": r["message"],
            })
        return self._send_json({"ok": True, "total": total, "items": items}, 200)

    # -- 3. GET /api/logs/<id> --
    def handle_logs_one(self, event_id: str):
        if not re.match(r"^[A-Za-z0-9_\-\.]+$", event_id):
            return self._send_json({"ok": False, "error": "not_found"}, 404)
        p = event_file_for(event_id)
        if p is None or not os.path.exists(p):
            return self._send_json({"ok": False, "error": "not_found"}, 404)
        try:
            with open(p, "rb") as f:
                data = f.read()
            # 校验 JSON
            json.loads(data.decode("utf-8"))
        except Exception:
            return self._send_json({"ok": False, "error": "corrupt"}, 500)
        return self._send_bytes(data, "application/json; charset=utf-8", 200)

    # -- 4. GET /api/logs/download.zip --
    def handle_logs_download(self, qs):
        _, records = self._filtered_records(qs, apply_limit=True, for_download=True)
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
            for r in records:
                ap = os.path.join(ROOT, r["_path"]) if r.get("_path") else None
                data = None
                if ap and os.path.exists(ap):
                    try:
                        with open(ap, "rb") as f:
                            data = f.read()
                    except Exception:
                        data = None
                if data is None and r.get("_report") is not None:
                    data = json.dumps(r["_report"], ensure_ascii=False, indent=2).encode("utf-8")
                if data is None:
                    continue
                zf.writestr(r["event_id"] + ".json", data)
        blob = buf.getvalue()
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Length", str(len(blob)))
        self.send_header("Content-Disposition", 'attachment; filename="ziyan_logs.zip"')
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(blob)

    # -- 4b. GET /api/logs/export_desktop --
    # 把筛选后的日志真实写入 ~/Desktop/ziyan错误日志/<时间戳>/
    def handle_logs_export_desktop(self, qs):
        _filtered, records = self._filtered_records(qs, apply_limit=True, for_download=True)
        stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        desktop = os.path.expanduser("~/Desktop")
        out_dir = os.path.join(desktop, "ziyan错误日志", stamp)
        try:
            os.makedirs(out_dir, exist_ok=True)
        except Exception as e:
            return self._send_json({"ok": False, "error": "mkdir_failed: %s" % e}, 500)

        written = []
        for r in records:
            ap = os.path.join(ROOT, r["_path"]) if r.get("_path") else None
            data = None
            if ap and os.path.exists(ap):
                try:
                    with open(ap, "rb") as f:
                        data = f.read()
                except Exception:
                    data = None
            if data is None and r.get("_report") is not None:
                data = json.dumps(r["_report"], ensure_ascii=False, indent=2).encode("utf-8")
            if data is None:
                continue
            dest = os.path.join(out_dir, r["event_id"] + ".json")
            tmp = dest + ".tmp"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, dest)
            written.append(dest)

        zip_path = os.path.join(out_dir, "ziyan_logs_%s.zip" % stamp)
        zp_tmp = zip_path + ".tmp"
        with zipfile.ZipFile(zp_tmp, "w", zipfile.ZIP_DEFLATED) as zf:
            for f in written:
                zf.write(f, os.path.basename(f))
        os.replace(zp_tmp, zip_path)

        if not written:
            return self._send_json({"ok": False, "error": "no_records", "dir": out_dir}, 404)
        return self._send_json({
            "ok": True,
            "dir": out_dir,
            "zip": zip_path,
            "count": len(written),
            "files": [os.path.basename(f) for f in written][:50],
        })

    # -- 5. POST /api/hotupdate/publish --
    def handle_hotupdate_publish(self):
        raw = self._read_body()
        if not raw:
            try:
                refresh_apt_dist()
            except Exception:
                pass
            return self._send_json({"ok": False, "error": "empty_body"}, 400)
        try:
            body = json.loads(raw.decode("utf-8"))
        except Exception:
            return self._send_json({"ok": False, "error": "invalid_json"}, 400)
        if not isinstance(body, dict):
            return self._send_json({"ok": False, "error": "invalid_json"}, 400)
        version = str(body.get("version", "")).strip()
        channel = str(body.get("channel", "stable")).strip() or "stable"
        package_path = str(body.get("package_path", "")).strip()
        architecture = str(body.get("architecture", "")).strip()
        min_os = str(body.get("min_os", "")).strip()
        max_os = str(body.get("max_os", "")).strip()
        ziyan_min = str(body.get("ziyan_min", "")).strip()
        notes = str(body.get("notes", ""))
        want_sha = str(body.get("sha256", "")).strip().lower()
        if not version:
            return self._send_json({"ok": False, "error": "missing_version"}, 400)
        if not re.match(r"^[A-Za-z0-9_\-\.\+]+$", version):
            return self._send_json({"ok": False, "error": "bad_version"}, 400)
        if not package_path or not os.path.isabs(package_path):
            return self._send_json({"ok": False, "error": "bad_package_path"}, 400)
        if not os.path.isfile(package_path):
            return self._send_json({"ok": False, "error": "package_not_found"}, 400)
        if architecture not in ("iphoneos-arm", "iphoneos-arm64"):
            return self._send_json({"ok": False, "error": "bad_architecture"}, 400)
        if not min_os or not max_os or not ziyan_min:
            return self._send_json({"ok": False, "error": "missing_compat"}, 400)
        # 计算 sha256 + size
        try:
            digest = sha256_file(package_path)
            size = file_size(package_path)
        except Exception as e:
            return self._send_json({"ok": False, "error": "read_package: %s" % e}, 500)
        if want_sha and want_sha != digest.lower():
            return self._send_json({"ok": False, "error": "sha256_mismatch", "expect": digest}, 400)
        fname = os.path.basename(package_path)
        dest_dir = os.path.join(packages_dir(), version)
        os.makedirs(dest_dir, exist_ok=True)
        dest = os.path.join(dest_dir, fname)
        # 原子复制：先写临时文件再 replace（支持大文件分块）
        import random
        tmp = dest + ".tmp.%d.%d" % (os.getpid(), random.randint(0, 1 << 30))
        try:
            h = hashlib.sha256()
            with open(package_path, "rb") as src, open(tmp, "wb") as dst:
                for chunk in iter(lambda: src.read(1024 * 1024), b""):
                    h.update(chunk)
                    dst.write(chunk)
                dst.flush()
                try:
                    os.fsync(dst.fileno())
                except Exception:
                    pass
            # 二次确认
            if h.hexdigest().lower() != digest.lower():
                try:
                    os.remove(tmp)
                except Exception:
                    pass
                return self._send_json({"ok": False, "error": "copy_hash_mismatch"}, 500)
            os.replace(tmp, dest)
        except Exception as e:
            try:
                if os.path.exists(tmp):
                    os.remove(tmp)
            except Exception:
                pass
            return self._send_json({"ok": False, "error": "copy_failed: %s" % e}, 500)
        url = "/hotupdate/packages/%s/%s" % (version, fname)
        published_at = now_str()
        with MANIFEST_LOCK:
            man = load_manifest()
            vers = man.get("versions", [])
            entry = {
                "version": version,
                "channel": channel,
                "file": fname,
                "url": url,
                "sha256": digest,
                "size": size,
                "architecture": architecture,
                "min_os": min_os,
                "max_os": max_os,
                "ziyan_min": ziyan_min,
                "notes": notes,
                "published_at": published_at,
            }
            replaced = False
            for i, v in enumerate(vers):
                if v.get("version") == version:
                    vers[i] = entry
                    replaced = True
                    break
            if not replaced:
                vers.append(entry)
            man["versions"] = vers
            ch = man.get("channels", {})
            ch[channel] = version
            man["channels"] = ch
            man["updated_at"] = published_at
            text = json.dumps(man, ensure_ascii=False, indent=2)
            atomic_write_text(manifest_path(), text)
        return self._send_json({"ok": True, "version": version, "sha256": digest, "url": url, "size": size, "channel": channel}, 200)

    # -- 6. GET /api/hotupdate/check --
    def handle_hotupdate_check(self, qs):
        def q(name, default=""):
            v = qs.get(name, [default])[0]
            return v.strip() if isinstance(v, str) else default
        device_id = q("device_id", "")
        os_ver = q("os", "")
        arch = q("arch", "")
        ziyan = q("ziyan", "")
        channel = q("channel", "stable") or "stable"
        man = load_manifest()
        ch = man.get("channels", {})
        vers = man.get("versions", [])
        target_ver = ch.get(channel, "")
        # 多架构机队（rootful arm + rootless arm64）：先看头指针，头不兼容时
        # 回退到"该 channel 中最新且与设备兼容"的版本；都不兼容才判 device_incompatible。
        candidates = [v for v in vers if v.get("channel") == channel]
        if not candidates:
            return self._send_json({"ok": True, "update": False, "reason": "no_update",
                                    "detail": "channel '%s' has no published version" % channel}, 200)
        head = next((v for v in candidates if v.get("version") == target_ver), None)
        ordered = ([head] if head else []) + [v for v in candidates if v is not head]
        ordered.sort(key=lambda v: (v is head, v.get("published_at", "")), reverse=True)
        def reasons_for(v):
            out = []
            if not arch_match(v.get("architecture", ""), arch):
                out.append("arch mismatch: package %s vs device %s" % (v.get("architecture", ""), arch or "(empty)"))
            try:
                if not version_ge(ziyan or "0", v.get("ziyan_min", "0")):
                    out.append("ziyan %s < min %s" % (ziyan or "(empty)", v.get("ziyan_min", "")))
            except Exception:
                out.append("bad ziyan version")
            try:
                if not (version_ge(os_ver or "0", v.get("min_os", "0")) and version_le(os_ver or "0", v.get("max_os", "0"))):
                    out.append("os %s not in [%s,%s]" % (os_ver or "(empty)", v.get("min_os", ""), v.get("max_os", "")))
            except Exception:
                out.append("bad os version")
            return out

        entry = None
        head_fails = []
        for v in ordered:
            fails = reasons_for(v)
            if not fails:
                entry = v
                break
            if v is head or not head_fails:
                head_fails = fails
        if entry is None:
            return self._send_json({"ok": True, "update": False, "reason": "device_incompatible",
                                    "detail": "; ".join(head_fails) or "no compatible version"}, 200)
        return self._send_json({
            "ok": True,
            "update": True,
            "version": entry.get("version", ""),
            "sha256": entry.get("sha256", ""),
            "url": entry.get("url", ""),
            "size": int(entry.get("size", 0)),
        }, 200)

    # -- 7. GET /hotupdate/manifest.json --
    # -- APT dist（本地自签 LAN 验证）--
    def _serve_bytes(self, data, ctype, name=None):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        if name:
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
        self.end_headers()
        self.wfile.write(data)

    def handle_apt_file(self, name):
        d = _apt_dist_dir()
        try:
            refresh_apt_dist()
        except Exception:
            pass
        if name == "ziyan-apt-key.asc":
            try:
                _apt_key()
            except Exception:
                pass
            if os.path.exists(SIGNING_PUB_FILE):
                with open(SIGNING_PUB_FILE, "rb") as fh:
                    return self._serve_bytes(fh.read(), "text/plain")
            return self._send_json({"ok": False, "error": "no_pubkey"}, 404)
        if name == "InRelease":
            # 本地自签说明文件：明确不是 GPG clearsign（见 dist/APT_SIGNING.md）
            note = ("NOTE: local self-signed LAN repo.\n"
                    "SIGNING=" + APT_SIGNING_NOTE + "\n"
                    "VERIFY: GET /apt/Release + /apt/Release.gpg + /apt/ziyan-apt-key.asc, "
                    "verify detached OpenPGP signature with the published key.\n")
            return self._serve_bytes(note.encode("utf-8"), "text/plain")
        p = os.path.join(d, name)
        if not os.path.isfile(p):
            if name in ("Release", "Release.gpg"):
                return self._send_json({"ok": False, "error": "unsigned_yet",
                                        "hint": "publish a package first"}, 404)
            return self._send_json({"ok": False, "error": "not_found"}, 404)
        ctype = "application/octet-stream" if name.endswith(".gpg") else "text/plain"
        with open(p, "rb") as fh:
            return self._serve_bytes(fh.read(), ctype)

    def handle_apt_packages(self, path):
        d = _apt_dist_dir()
        try:
            refresh_apt_dist()
        except Exception:
            pass
        # /apt/dists/stable/main/binary-<arch>/Packages
        m = re.match(r"^/apt/(?:dists/stable/)?(main/binary-[A-Za-z0-9_\-]+/Packages)$", path)
        if not m:
            return self._send_json({"ok": False, "error": "bad_packages_path"}, 404)
        p = os.path.join(d, m.group(1))
        if not os.path.isfile(p):
            return self._send_json({"ok": False, "error": "not_found"}, 404)
        with open(p, "rb") as fh:
            return self._serve_bytes(fh.read(), "text/plain")

    def handle_apt_pool(self, rel):
        # rel 形如 <version>/<file>，映射回 hotupdate/packages 下真实文件
        if ".." in rel or rel.startswith("/"):
            return self._send_json({"ok": False, "error": "bad_pool_path"}, 404)
        src = os.path.join(ROOT, "hotupdate", "packages", rel)
        if not os.path.isfile(src):
            return self._send_json({"ok": False, "error": "not_found"}, 404)
        return self.handle_package_file(rel)

    def handle_manifest(self):
        man = load_manifest()
        body = json.dumps(man, ensure_ascii=False, indent=2).encode("utf-8")
        return self._send_bytes(body, "application/json; charset=utf-8", 200)

    # -- 8. GET /hotupdate/packages/...（支持 Range）--
    def handle_package_file(self, rel: str, head_only=False):
        rel = urllib.parse.unquote(rel)
        # 防穿越
        norm = os.path.normpath(rel)
        if norm.startswith("..") or os.path.isabs(norm):
            return self._send_json({"ok": False, "error": "not_found"}, 404)
        ap = os.path.join(packages_dir(), norm)
        arp = os.path.realpath(ap)
        base = os.path.realpath(packages_dir())
        if not (arp == base or arp.startswith(base + os.sep)):
            return self._send_json({"ok": False, "error": "not_found"}, 404)
        if not os.path.isfile(arp):
            return self._send_json({"ok": False, "error": "not_found"}, 404)
        ctype, _ = mimetypes.guess_type(arp)
        if not ctype:
            ctype = "application/octet-stream"
        if ctype.startswith("text/"):
            ctype = "application/octet-stream"
        total = os.path.getsize(arp)
        rg = self.headers.get("Range")
        start, end = 0, total - 1
        status = 200
        if rg:
            m = re.match(r"^\s*bytes\s*=\s*(\d*)-(\d*)\s*$", rg)
            if m:
                s, e = m.group(1), m.group(2)
                try:
                    if s == "" and e != "":
                        # 后缀 N 字节
                        n = int(e)
                        if n > 0:
                            start = max(0, total - n)
                            end = total - 1
                            status = 206
                    elif s != "":
                        start = int(s)
                        end = int(e) if e != "" else total - 1
                        if start >= total:
                            self.send_response(416)
                            self.send_header("Content-Range", "bytes */%d" % total)
                            self.send_header("Content-Length", "0")
                            self.end_headers()
                            return
                        if end >= total:
                            end = total - 1
                        if end < start:
                            self.send_response(416)
                            self.send_header("Content-Range", "bytes */%d" % total)
                            self.send_header("Content-Length", "0")
                            self.end_headers()
                            return
                        status = 206 if (start != 0 or end != total - 1) else 200
                except Exception:
                    start, end = 0, total - 1
                    status = 200
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        fname = os.path.basename(arp)
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % fname)
        if status == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, total))
        self.end_headers()
        if head_only:
            return
        try:
            with open(arp, "rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(1024 * 256, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except BrokenPipeError:
            pass

    # -- 9. GET / --
    def handle_root(self):
        idx = os.path.join(SERVER_DIR, "index.html")
        if not os.path.exists(idx):
            body = "<h1>ZiYan log server: index.html missing</h1>".encode("utf-8")
            return self._send_bytes(body, "text/html; charset=utf-8", 500)
        with open(idx, "rb") as f:
            data = f.read()
        return self._send_bytes(data, "text/html; charset=utf-8", 200)


def main():
    global ROOT
    ap = argparse.ArgumentParser(description="ZiYan log server v1")
    ap.add_argument("--root", default=DEFAULT_ROOT, help="data root")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT, help="listen port")
    ap.add_argument("--host", default="0.0.0.0", help="listen host")
    args = ap.parse_args()
    ROOT = os.path.abspath(args.root)
    ensure_dirs()
    print("ZiYan log server v1 root=%s port=%d" % (ROOT, args.port), flush=True)
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.daemon_threads = True
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    main()
