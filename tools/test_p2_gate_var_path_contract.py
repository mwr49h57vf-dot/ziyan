#!/usr/bin/env python3
"""Contract checks for the Z2-30M gate: scheme resolution and auditability.

Root cause guarded here (2026-09-10): .101 is rootful but had a leftover
/var/jb/usr/lib/ziyan/var from Sep 1. The gate picked the var directory by
testing for that path, so .ziyan_color_req landed in a dead directory and every
minute reported REQ=100 / empty COLOR -- an environment bug that looked like a
product FAIL at minute 1.
"""

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "tools" / "zy_p2_c98_30m_gate.sh"


class P2GateVarPathContract(unittest.TestCase):
    def setUp(self) -> None:
        self.source = GATE.read_text(encoding="utf-8")

    def test_gate_script_parses(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)

    def test_scheme_is_not_chosen_by_directory_existence(self) -> None:
        self.assertNotIn(
            "if [ -d /var/jb/usr/lib/ziyan/var ]; then", self.source
        )
        self.assertIn("ZY_ARCH=$(dpkg-query -W -f='${Architecture}'", self.source)

    def test_case_statement_is_not_used_inside_command_substitution_heredoc(self) -> None:
        # bash 3.2 parses a heredoc body inside $( ) as code, so `;;` there is a
        # hard syntax error that kills the gate before the final snapshot runs.
        snap = self.source.split("<<'SNAP'", 1)[1].split("\nSNAP", 1)[0]
        self.assertNotIn(";;", snap)

    def test_meta_records_per_host_effective_overrides(self) -> None:
        self.assertIn("per-host effective overrides", self.source)
        self.assertIn("color_for \"$h\"", self.source)

    def test_report_last_color_does_not_match_expected_color(self) -> None:
        # 贪婪的 s/.*COLOR=.../ 会把 EXPECTED_COLOR 当成实测值，报告整列失真。
        self.assertIn("s/.* EXPECTED_APP=[^ ]* COLOR=", self.source)

    def test_device61_prefers_key_authentication(self) -> None:
        # .61 密码通道间歇性拒登；mobile 也必须先试密钥，否则 30 分钟必有假 FAIL。
        self.assertNotIn('if [ "$user" = mobile ]; then\n    sshpass', self.source)

    def test_go_home_carries_owner_token_required_since_20260904(self) -> None:
        # Tweak.m 只接受 owner=com.ziyan.ziyan 且前台为 ZiYan App 的远程 Home。
        # 裸写 1 会被 policy_reject_missing_ziyan_owner 拒绝，误报成产品 FAIL。
        self.assertIn("owner=com.ziyan.ziyan", self.source)
        self.assertNotIn("printf '1\\n' >\"$V/.ziyan_go_home\"", self.source)
        self.assertIn("OWNER_FRONT=", self.source)

    def test_go_home_is_written_atomically(self) -> None:
        # SB 侧读完即删；非原子写被读到截断空文件会让 Home 静默丢失。
        self.assertIn('>"$V/.ziyan_go_home.tmp"', self.source)
        self.assertIn('mv "$V/.ziyan_go_home.tmp" "$V/.ziyan_go_home"', self.source)

    def test_framecap_count_excludes_other_greps(self) -> None:
        # 看门狗自身 `grep -F ziyan_framecap serve` 会被旧计数算成第 2 个宿主。
        fc_n_line = [
            line for line in self.source.splitlines() if line.startswith("fc_n()")
        ]
        self.assertEqual(len(fc_n_line), 1)
        self.assertIn("grep -v grep", fc_n_line[0])

    def test_accepts_all_five_acceptance_devices(self) -> None:
        self.assertIn("HOSTS=(101 112 166 53 61)", self.source)
        self.assertIn("case \"$h\" in 53|61|101|112|166)", self.source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
