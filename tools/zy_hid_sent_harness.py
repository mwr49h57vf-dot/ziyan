#!/usr/bin/env python3
"""Offline harness for LEARNING-gated .ziyan_hid_sent probe. Not a device PASS."""
import tempfile
from pathlib import Path


def parse_learn(text):
    sid, bid = "", ""
    active_one = False
    lines = text.splitlines()
    if lines and lines[0].strip() == "1":
        active_one = True
    for line in lines:
        if line.startswith("session_id="):
            sid = line[11:].strip()
        elif line.startswith("bundle_id="):
            bid = line[10:].strip()
    return sid, bid, active_one


def session_is_learning(text):
    return any(line.strip() == "state=LEARNING" for line in text.splitlines())


def should_write(phase, hid_ok, learning, learn_active_one, session_id, target, front, existing):
    if not hid_ok:
        return False
    if phase != "up":
        return False
    if not learning:
        return False
    if not learn_active_one:
        return False
    if not session_id or not target:
        return False
    if not front or front != target:
        return False
    if existing and f"request_id={session_id}" in existing:
        return False
    return True


def main():
    fail = 0

    def check(name, cond):
        nonlocal fail
        print(("[PASS]" if cond else "[FAIL]"), name)
        fail += 0 if cond else 1

    args_ok = dict(phase="up", hid_ok=True, learning=True, learn_active_one=True,
                   session_id="s1", target="com.ownbook.notes",
                   front="com.ownbook.notes", existing="")
    check("skip hidOk false", not should_write(**{**args_ok, "hid_ok": False}))
    check("skip down", not should_write(**{**args_ok, "phase": "down"}))
    check("skip not LEARNING", not should_write(**{**args_ok, "learning": False}))
    check("skip learn_active not 1", not should_write(**{**args_ok, "learn_active_one": False}))
    check("skip empty session", not should_write(**{**args_ok, "session_id": ""}))
    check("skip empty target", not should_write(**{**args_ok, "target": ""}))
    check("skip front mismatch", not should_write(**{**args_ok, "front": "com.apple.springboard"}))
    check("write first up match", should_write(**args_ok))
    check("skip same request", not should_write(**{**args_ok, "existing": "request_id=s1\n"}))
    check("repeat other session", should_write(**{**args_ok, "session_id": "s2", "existing": "request_id=s1\n"}))

    sid, bid, one = parse_learn("1\nbundle_id=com.ownbook.notes\nsession_id=ags_1\n")
    check("parse sid", sid == "ags_1")
    check("parse bid", bid == "com.ownbook.notes")
    check("parse active 1", one)
    check("parse session LEARNING", session_is_learning("state=LEARNING\nactive=1\n"))
    check("parse session COMPLETED not learning", not session_is_learning("state=COMPLETED\n"))

    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / ".ziyan_hid_sent"
        body = (
            "device=unknown\nphase=up\nhidOk=1\nfront_bundle=com.ownbook.notes\n"
            "target_bundle=com.ownbook.notes\ntimestamp_ms=1\nrequest_id=ags_1\n"
            "result=sent\nerror_code=HID_INJECT_OK\nstate=LEARNING\n"
        )
        p.write_text(body)
        check("fields", all(k in p.read_text() for k in (
            "device=", "phase=", "hidOk=", "front_bundle=", "target_bundle=",
            "timestamp_ms=", "request_id=", "result=", "error_code=", "state=LEARNING")))
        missing = Path(td) / "no_such_dir" / ".ziyan_hid_sent"
        try:
            missing.write_text(body)
            wrote_missing = True
        except OSError:
            wrote_missing = False
        check("write fail when parent missing", not wrote_missing)
        first = should_write(**{**args_ok, "session_id": "ags_1"})
        second = should_write(**{**args_ok, "session_id": "ags_1", "existing": p.read_text()})
        check("continuous first then repeat blocked", first and not second)

    print("-----")
    print("ZIYAN_HID_SENT_HARNESS=" + ("PASS" if fail == 0 else f"FAIL count={fail}"))
    raise SystemExit(fail)


if __name__ == "__main__":
    main()
