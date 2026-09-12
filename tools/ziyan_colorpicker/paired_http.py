"""Ephemeral pairing for the device's native screenshot service."""
import http.client
import json
import threading
import time
import urllib.parse


class PairingRequired(RuntimeError):
    pass


class PairedHTTP:
    def __init__(self):
        self.ip = None
        self.port = None
        self.last_ms = 0
        self._lock = threading.Lock()
        self._epoch = 0
        self._token = None
        self._expires = 0

    def invalidate(self):
        with self._lock:
            self.port = None
            self._token = None
            self._expires = 0
            self._epoch += 1

    def set_ip(self, ip):
        ip = ip.strip()
        with self._lock:
            if ip != self.ip:
                self.ip, self.port, self._token, self._expires = ip, None, None, 0
                self._epoch += 1

    def context(self, ip, ports, authenticated=True):
        with self._lock:
            if self.ip is None:
                self.ip = ip
            if self.ip != ip:
                raise RuntimeError("设备已切换，请重新发起请求")
            if authenticated and self._token and time.monotonic() >= self._expires:
                self._token = None
                raise PairingRequired("配对已过期，请在设备上重新开启配对")
            candidates = [self.port] if self._token and self.port else list(dict.fromkeys(([self.port] if self.port else []) + list(ports)))
            return self._epoch, self._token if authenticated else None, candidates

    def remember_port(self, ip, epoch, port):
        with self._lock:
            if self.ip == ip and self._epoch == epoch:
                self.port = port

    def request(self, ip, port, method, path, body=None, token=None, timeout=8):
        headers = {"Connection": "close", "User-Agent": "ZiYanColorPicker"}
        if token:
            headers["Authorization"] = "Bearer " + token
        if body is not None:
            body = urllib.parse.urlencode(body).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        conn = http.client.HTTPConnection(ip, port, timeout=timeout)
        try:
            conn.request(method, path, body=body, headers=headers)
            response = conn.getresponse()
            raw = response.read(32 * 1024 * 1024 + 1)
            if len(raw) > 32 * 1024 * 1024:
                raise RuntimeError("设备响应超过上限")
            if response.status in (401, 403):
                raise PairingRequired("配对无效或已撤销，请在设备上开启配对后重新输入配对码")
            if response.status != 200:
                raise RuntimeError("HTTP %d: %s" % (response.status, raw[:160].decode("utf-8", "replace")))
            return raw
        finally:
            conn.close()

    def pair_with_ports(self, ip, code, ports):
        epoch, _, candidates = self.context(ip, ports, authenticated=False)
        last = "设备未开启局域网配对"
        for port in candidates:
            try:
                result = json.loads(self.request(ip, port, "POST", "/pair", {"code": code.strip()}))
                token = result.get("token")
                if not isinstance(token, str) or not token:
                    raise PairingRequired("设备未返回有效配对凭证")
                ttl = min(900, max(0, int(result.get("expires_in", 0))))
                if not ttl:
                    raise PairingRequired("配对已过期")
                with self._lock:
                    if self.ip != ip or self._epoch != epoch:
                        raise RuntimeError("设备已切换，已丢弃配对结果")
                    self.port, self._token = port, token
                    self._expires = time.monotonic() + ttl
                return "已配对，有效期 %d 分钟" % (ttl // 60)
            except PairingRequired:
                raise
            except (OSError, http.client.HTTPException) as exc:
                last = str(exc)
        raise RuntimeError(last)

    def revoke_with_ports(self, ip, ports):
        epoch, token, candidates = self.context(ip, ports)
        try:
            self.request(ip, candidates[0], "POST", "/pairing/revoke", {"revoke": 1}, token)
        finally:
            with self._lock:
                if self.ip == ip and self._epoch == epoch:
                    self._token, self._expires = None, 0
                    self._epoch += 1
