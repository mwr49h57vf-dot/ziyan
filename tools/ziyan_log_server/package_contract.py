"""Debian version and package metadata validation. No archive extraction or shell."""
import io
import re
import tarfile


def split_version(value):
    value = str(value)
    if not re.fullmatch(r"(?:\d+:)?\d[A-Za-z0-9.+:~\-]*", value):
        raise ValueError("bad_version")
    epoch, rest = value.split(":", 1) if ":" in value else ("0", value)
    upstream, revision = rest.rsplit("-", 1) if "-" in rest else (rest, "0")
    if not upstream or not revision or not re.fullmatch(r"[A-Za-z0-9+.~]+", revision):
        raise ValueError("bad_version")
    return int(epoch), upstream, revision


def _part_cmp(left, right):
    def order(char):
        if char == "~":
            return -1
        if not char or char.isdigit():
            return 0
        return ord(char) if char.isalpha() else ord(char) + 256
    i = j = 0
    while i < len(left) or j < len(right):
        while (i < len(left) and not left[i].isdigit()) or (j < len(right) and not right[j].isdigit()):
            a = order(left[i] if i < len(left) else "")
            b = order(right[j] if j < len(right) else "")
            if a != b:
                return (a > b) - (a < b)
            i += i < len(left)
            j += j < len(right)
        while i < len(left) and left[i] == "0":
            i += 1
        while j < len(right) and right[j] == "0":
            j += 1
        ie, je = i, j
        while ie < len(left) and left[ie].isdigit():
            ie += 1
        while je < len(right) and right[je].isdigit():
            je += 1
        a, b = left[i:ie], right[j:je]
        if len(a) != len(b):
            return (len(a) > len(b)) - (len(a) < len(b))
        if a != b:
            return (a > b) - (a < b)
        i, j = ie, je
    return 0


def cmp_version(left, right):
    a, b = split_version(left), split_version(right)
    return ((a[0] > b[0]) - (a[0] < b[0])) or _part_cmp(a[1], b[1]) or _part_cmp(a[2], b[2])


def deb_metadata(path):
    members = {}
    with open(path, "rb") as f:
        if f.read(8) != b"!<arch>\n":
            raise ValueError("not_a_deb")
        while header := f.read(60):
            if len(header) != 60 or header[-2:] != b"`\n":
                raise ValueError("bad_deb_archive")
            name = header[:16].decode("ascii").strip().rstrip("/")
            size = int(header[48:58].strip())
            if size < 0 or size > 300 * 1024 * 1024 or name in members:
                raise ValueError("bad_deb_member")
            data = f.read(size)
            if len(data) != size or (size % 2 and f.read(1) != b"\n"):
                raise ValueError("truncated_deb")
            members[name] = data
    controls = [name for name in members if re.fullmatch(r"control\.tar(?:\.(?:gz|xz|bz2|lzma))?", name)]
    payloads = [name for name in members if re.fullmatch(r"data\.tar(?:\.(?:gz|xz|bz2|lzma))?", name)]
    if members.get("debian-binary") != b"2.0\n" or len(controls) != 1 or len(payloads) != 1 or len(members) != 3:
        raise ValueError("unsupported_or_invalid_deb")
    with tarfile.open(fileobj=io.BytesIO(members[controls[0]]), mode="r:*") as tf:
        entries = tf.getmembers()
        controls = [x for x in entries if x.name in ("control", "./control") and x.isfile()]
        if len(controls) != 1 or controls[0].size > 64 * 1024 or len(entries) > 100:
            raise ValueError("bad_deb_control")
        control = tf.extractfile(controls[0]).read().decode("utf-8")
    # A valid control-only ar archive is not an installable package.
    with tarfile.open(fileobj=io.BytesIO(members[payloads[0]]), mode="r:*") as tf:
        count = total = 0
        for entry in tf:
            count += 1
            total += entry.size
            if count > 100000 or total > 2 * 1024 * 1024 * 1024:
                raise ValueError("deb_payload_too_large")
        if count == 0:
            raise ValueError("empty_deb_payload")
    fields = {}
    key = None
    for line in control.splitlines():
        if line.startswith((" ", "\t")) and key:
            fields[key] += " " + line.strip()
        elif ":" in line:
            key, value = line.split(":", 1)
            key = key.lower()
            if key in fields:
                raise ValueError("duplicate_control_field")
            fields[key] = value.strip()
        elif line.strip():
            raise ValueError("invalid_control_field")
    if fields.get("package") != "com.ziyan.ziyan":
        raise ValueError("wrong_package")
    split_version(fields.get("version", ""))
    if fields.get("architecture") not in ("iphoneos-arm", "iphoneos-arm64"):
        raise ValueError("bad_architecture")
    minimum = re.search(r"(?:^|,)\s*firmware\s*\(>=\s*([0-9.]+)\s*\)", fields.get("depends", ""))
    if not minimum:
        raise ValueError("missing_firmware_dependency")
    return {"package": fields["package"], "version": fields["version"], "architecture": fields["architecture"],
            "min_os": minimum[1], "max_os": fields.get("x-ziyan-max-os", ""),
            "ziyan_min": fields.get("x-ziyan-min-version", "")}
