#!/usr/bin/env python3
"""Device .61 mobile transport must be key-first.

History: the first version forced `PubkeyAuthentication=no` for mobile to avoid
consuming MaxAuthTries on local keys. On 2026-09-11 that proved wrong: .61's
password channel is intermittent (about 1 reject in 3) and the devices' sshd
rate-limits password auth, so a five-device E48 matrix died mid-run with rc=255
(.101 8/9, .112 0/9, .166 4/9, .53 0/9) while the key path stayed stable and
.61 finished 9/9. The invariant is now: try the deployed key first without any
password attempt; fall back to sshpass only when the key is unavailable.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# 这 3 个脚本必须密钥优先且不得对 mobile 走「密码独占」分支。
KEY_FIRST_SCRIPTS = (
    "tools/zy_pretest_clean_4phone.sh",
    "tools/zy_p2_c98_30m_gate.sh",
    "tools/zy_z1_mem_c98_gate.sh",
)

# E48 矩阵默认密钥传输；密码路径只在显式 E48_TRANSPORT=password 时启用。
MATRIX = "tools/e48_device112_sample_matrix.sh"


def main() -> None:
    for relative in KEY_FIRST_SCRIPTS:
        source = (ROOT / relative).read_text()
        assert 'if [ "$user" = mobile ]; then\n    sshpass' not in source, relative
        assert "BatchMode=yes" in source, relative

    matrix = (ROOT / MATRIX).read_text()
    assert 'if [ "${E48_TRANSPORT:-key}" = password ]' in matrix, MATRIX
    assert 'SSH=(ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$IP")' in matrix, MATRIX
    # 旧密码分支的约束必须保留，供未部署密钥的机器使用。
    assert "-o PubkeyAuthentication=no" in matrix, MATRIX
    assert "-o PreferredAuthentications=password" in matrix, MATRIX
    print("DEVICE61_TRANSPORT_CONTRACT=PASS key_first=3 matrix=key_default")


if __name__ == "__main__":
    main()
