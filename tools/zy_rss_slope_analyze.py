#!/usr/bin/env python3
"""RSS 斜率离线分析（Z0-METRIC）

设备端 shell 没有 awk，只能算「首/末窗口中位数之差」。framecap 与 TSDaemon 的
RSS 都是周期约 60s、振幅约 3MB 的锯齿，短窗口下这个估计量测到的是采样相位而
不是趋势 —— 触动 .171 在 5min 窗口测出 +99 KB/100s，同一台机在 20min 窗口测出
0.0，就是这个原因。

本工具在 Mac 侧对完整样本序列做两种估计并列输出：
  median  首/末 15 点中位数之差（与设备端门禁同口径，便于对照）
  ols     全样本最小二乘斜率（抗相位，作为趋势真值）

输入格式（自动识别）：
  TS 采样器  tmp_shots/TS_OBS/*/rss_<host>.txt   行首 "SAMPLE <ts> <rss> ..."
  E4 资源表  .ziyan_e4_resource.tsv              列 "t fc_n fc_rss sb_rss keep life"

用法:
  python3 tools/zy_rss_slope_analyze.py <file> [file ...]
"""
import sys
import statistics


def load(path):
    """返回 [(ts, rss_kb), ...]"""
    rows = []
    with open(path, errors="ignore") as fh:
        for line in fh:
            if line.startswith("SAMPLE "):
                f = line.split()
                if len(f) >= 3:
                    try:
                        rows.append((int(f[1]), int(f[2])))
                    except ValueError:
                        pass
            elif "\t" in line:
                f = line.rstrip("\n").split("\t")
                # t  fc_n  fc_rss  sb_rss  keep  life
                if len(f) >= 3 and f[0].isdigit() and f[2].isdigit():
                    rows.append((int(f[0]), int(f[2])))
    return rows


def median_estimator(rows, n=15):
    if len(rows) < 2 * n:
        n = max(3, len(rows) // 4)
    head, tail = rows[:n], rows[-n:]
    base = statistics.median(r[1] for r in head)
    end = statistics.median(r[1] for r in tail)
    dt = statistics.median(r[0] for r in tail) - statistics.median(r[0] for r in head)
    per100 = (end - base) * 100.0 / dt if dt > 0 else 0.0
    return base, end, dt, end - base, per100


def ols_slope(rows):
    """最小二乘斜率，归一化为 KB/100s。"""
    n = len(rows)
    t0 = rows[0][0]
    xs = [r[0] - t0 for r in rows]
    ys = [r[1] for r in rows]
    mx = sum(xs) / n
    my = sum(ys) / n
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    den = sum((x - mx) ** 2 for x in xs)
    return (num / den * 100.0) if den else 0.0


def main(paths):
    if not paths:
        print(__doc__)
        return 2
    print(f"{'file':<46} {'n':>5} {'win':>6} {'median/100s':>12} "
          f"{'ols/100s':>9} {'swing':>7}")
    for p in paths:
        rows = load(p)
        if len(rows) < 8:
            print(f"{p:<46} (样本不足: {len(rows)})")
            continue
        rows.sort()
        base, end, dt, delta, per100 = median_estimator(rows)
        ols = ols_slope(rows)
        vals = [r[1] for r in rows]
        win = rows[-1][0] - rows[0][0]
        name = p if len(p) <= 46 else "…" + p[-45:]
        print(f"{name:<46} {len(rows):>5} {win:>5}s {per100:>+11.1f} "
              f"{ols:>+8.1f} {max(vals) - min(vals):>6}")
        print(f"{'':<46} base={base:.0f} end={end:.0f} delta={delta:+.0f}KB "
              f"dt={dt:.0f}s min={min(vals)} max={max(vals)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
