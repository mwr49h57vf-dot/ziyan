#!/usr/bin/env python3
"""Verify expected APT packages, Release hashes, and an explicitly trusted keyring.

Example: verify_repo.py repo --trusted-keyring release.gpg
Use an operator-selected public keyring, never a key obtained from the repo itself.
"""
import argparse
import email.utils
import gzip
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile

ARCHITECTURES = ("iphoneos-arm", "iphoneos-arm64")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def paragraphs(text):
    records, fields, current = [], {}, None
    for line in [*text.splitlines(), ""]:
        if not line:
            if fields:
                records.append(fields)
            fields, current = {}, None
        elif line[0].isspace():
            if current is None:
                raise ValueError("continuation without a field")
            fields[current] += "\n" + line.strip()
        else:
            match = re.fullmatch(r"([A-Za-z0-9-]+):\s?(.*)", line)
            if not match or match[1] in fields:
                raise ValueError("malformed or duplicate field: " + line[:80])
            current = match[1]
            fields[current] = match[2]
    return records


def confined_file(base, name):
    relative = PurePosixPath(name)
    if (not name or "\\" in name or ":" in name or relative.is_absolute()
            or any(part in (".", "..") for part in name.split("/"))):
        raise ValueError("unsafe repository path: " + name)
    base = Path(base).resolve()
    path = (base / name).resolve(strict=True)
    if base not in path.parents or not path.is_file():
        raise ValueError("repository path escapes its root: " + name)
    return path


def command_path(executable, path):
    """Git for Windows' GnuPG consumes MSYS paths, native GnuPG does not."""
    program = Path(shutil.which(executable) or executable)
    cygpath = program.with_name("cygpath.exe")
    if os.name == "nt" and cygpath.is_file():
        return subprocess.run([str(cygpath), "-u", str(path)], capture_output=True,
                              text=True, check=True).stdout.strip()
    return str(path)


def verify_signatures(stable, trusted_keyring, gpgv):
    present = [name for name in ("Release.gpg", "InRelease") if (stable / name).exists()]
    print("SIGNATURE_FILES=" + ",".join(present))
    if not trusted_keyring:
        raise ValueError("TRUST_MATERIAL_REQUIRED: specify --trusted-keyring")
    keyring = Path(trusted_keyring).resolve(strict=True)
    if not keyring.is_file() or not keyring.stat().st_size:
        raise ValueError("trusted keyring is empty or not a file")
    print("TRUST_KEYRING_SHA256=" + sha256(keyring))
    if not present:
        raise ValueError("SIGNATURE_MISSING")
    # Isolate default keyrings; only the supplied public keyring grants trust.
    with tempfile.TemporaryDirectory(prefix="ziyan-gpgv-") as temporary:
        for name in present:
            signature = confined_file(stable, name)
            command = [gpgv, "--homedir", command_path(gpgv, temporary), "--keyring", command_path(gpgv, keyring), "--status-fd", "1"]
            if name == "InRelease":
                verified_text = Path(temporary) / "verified-release"
                command.extend(["--output", command_path(gpgv, verified_text), command_path(gpgv, signature)])
            else:
                command.extend([command_path(gpgv, signature), command_path(gpgv, confined_file(stable, "Release"))])
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
            fingerprints = re.findall(r"^\[GNUPG:\] VALIDSIG ([0-9A-F]+) ", result.stdout, re.M)
            if result.returncode != 0 or not fingerprints:
                raise ValueError("SIGNATURE_INVALID: " + name)
            if name == "InRelease" and verified_text.read_bytes() != (stable / "Release").read_bytes():
                raise ValueError("INRELEASE_CONTENT_MISMATCH")
            print("SIGNATURE_VERIFIED=" + name + " fingerprints=" + ",".join(fingerprints))


def main(repo, trusted_keyring=None, package="com.ziyan.ziyan", architectures=ARCHITECTURES,
         expected_count_per_arch=1, expected_version=None, gpgv="gpgv"):
    fails, checked = [], 0
    repo = Path(repo).resolve()
    stable = repo / "dists/stable"
    required_indexes = set()
    print("EXPECTED_PACKAGE=%s ARCHITECTURES=%s COUNT_PER_ARCH=%s" %
          (package, ",".join(architectures), expected_count_per_arch))
    if (not package or expected_count_per_arch < 1 or not architectures
            or len(set(architectures)) != len(architectures)
            or any(not re.fullmatch(r"[a-zA-Z0-9-]+", arch) for arch in architectures)):
        fails.append("INVALID_EXPECTATIONS")
        architectures = ()
    seen, filenames = set(), set()
    for arch in architectures:
        index = "main/binary-" + arch + "/Packages"
        required_indexes.update((index, index + ".gz"))
        try:
            path = confined_file(stable, index)
            records = paragraphs(path.read_text(encoding="utf-8"))
            if len(records) != expected_count_per_arch:
                raise ValueError("PACKAGE_COUNT %s got=%d want=%d" % (arch, len(records), expected_count_per_arch))
            compressed = confined_file(stable, index + ".gz")
            with gzip.open(compressed, "rb") as handle:
                if handle.read() != path.read_bytes():
                    raise ValueError("COMPRESSED_INDEX_MISMATCH " + index)
            for fields in records:
                for field in ("Package", "Version", "Architecture", "Filename", "Size", "SHA256", "Depends"):
                    if not fields.get(field):
                        raise ValueError("MISSING_PACKAGE_FIELD " + field)
                identity = (fields["Package"], fields["Version"], fields["Architecture"])
                if fields["Package"] != package or fields["Architecture"] != arch:
                    raise ValueError("UNEXPECTED_PACKAGE_IDENTITY " + repr(identity))
                if expected_version and fields["Version"] != expected_version:
                    raise ValueError("UNEXPECTED_VERSION " + fields["Version"])
                if identity in seen or fields["Filename"] in filenames:
                    raise ValueError("DUPLICATE_PACKAGE_RECORD " + repr(identity))
                seen.add(identity)
                filenames.add(fields["Filename"])
                payload = confined_file(repo, fields["Filename"])
                if not re.fullmatch(r"[0-9a-fA-F]{64}", fields["SHA256"]):
                    raise ValueError("INVALID_PACKAGE_SHA256")
                if not re.fullmatch(r"[0-9]+", fields["Size"]) or int(fields["Size"]) <= 0:
                    raise ValueError("INVALID_PACKAGE_SIZE")
                if sha256(payload) != fields["SHA256"].lower() or payload.stat().st_size != int(fields["Size"]):
                    raise ValueError("PACKAGE_MISMATCH " + fields["Filename"])
                checked += 1
                print("PACKAGE_VERIFIED=%s version=%s arch=%s sha256=%s" %
                      (package, fields["Version"], arch, fields["SHA256"].lower()))
        except (OSError, ValueError, EOFError) as exc:
            fails.append(str(exc))
    try:
        records = paragraphs(confined_file(stable, "Release").read_text(encoding="utf-8"))
        if len(records) != 1:
            raise ValueError("Release must contain exactly one record")
        release = records[0]
        for field in ("Origin", "Label", "Suite", "Codename", "Architectures", "Components", "Date", "SHA256"):
            if not release.get(field, "").strip():
                raise ValueError("MISSING_RELEASE_FIELD " + field)
        if release["Suite"] != "stable" or release["Codename"] != "stable" or release["Components"].split() != ["main"]:
            raise ValueError("UNEXPECTED_RELEASE_SUITE_OR_COMPONENT")
        if sorted(release["Architectures"].split()) != sorted(architectures):
            raise ValueError("RELEASE_ARCHITECTURES_MISMATCH")
        if email.utils.parsedate_to_datetime(release["Date"]).tzinfo is None:
            raise ValueError("RELEASE_DATE_REQUIRES_TIMEZONE")
        hashes = {}
        for line in release["SHA256"].splitlines():
            if not line.strip():
                continue
            match = re.fullmatch(r"([0-9a-fA-F]{64})\s+(\d+)\s+(\S+)", line.strip())
            if not match or match[3] in hashes:
                raise ValueError("MALFORMED_OR_DUPLICATE_RELEASE_HASH")
            hashes[match[3]] = (match[1].lower(), int(match[2]))
        if not required_indexes.issubset(hashes):
            raise ValueError("RELEASE_COVERAGE_MISSING " + ",".join(sorted(required_indexes - hashes.keys())))
        for name, (want_hash, want_size) in hashes.items():
            index_path = confined_file(stable, name)
            if sha256(index_path) != want_hash or index_path.stat().st_size != want_size:
                raise ValueError("RELEASE_MISMATCH " + name)
        print("RELEASE_FILES_VERIFIED=%d" % len(hashes))
    except (OSError, ValueError, TypeError) as exc:
        fails.append(str(exc))
    try:
        verify_signatures(stable, trusted_keyring, gpgv)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print("SIGNATURE_VERIFIED=False")
        fails.append(str(exc))
    print("CHECKED=%d" % checked)
    print("FAILS=%s" % (fails or "NONE"))
    return 1 if fails else 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", nargs="?", default="ziyan_apt_repo")
    parser.add_argument("--trusted-keyring")
    parser.add_argument("--package", default="com.ziyan.ziyan")
    parser.add_argument("--architectures", nargs="+", default=ARCHITECTURES)
    parser.add_argument("--expected-count-per-arch", type=int, default=1)
    parser.add_argument("--expected-version")
    parser.add_argument("--gpgv", default="gpgv")
    args = parser.parse_args()
    sys.exit(main(**vars(args)))
