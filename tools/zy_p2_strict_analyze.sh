#!/bin/bash
set -u

usage() {
  echo "Usage: $0 SAMPLES.txt [SUMMARY.txt]" >&2
}

if test "$#" -lt 1 || test "$#" -gt 2; then
  usage
  exit 2
fi

LOG="$1"
SUMMARY="${2:-}"
if test ! -f "$LOG"; then
  echo "ERROR: samples file not found: $LOG" >&2
  exit 2
fi

run_analysis() {
  analysis_ts=$(date '+%F %T')
  awk -v analysis_ts="$analysis_ts" '
  function value(name,    i, pair, prefix) {
    prefix = name "="
    for (i = 1; i <= NF; i++) {
      if (index($i, prefix) == 1) {
        return substr($i, length(prefix) + 1)
      }
    }
    return ""
  }
  function uint(v) {
    return v ~ /^[0-9]+$/
  }
  function add_error(message) {
    errors++
    error_text[errors] = message
  }
  function gate_text(ok) {
    return ok ? "PASS" : "FAIL"
  }
  function sort_values(values, count,    i, j, tmp) {
    for (i = 2; i <= count; i++) {
      tmp = values[i]
      j = i - 1
      while (j >= 1 && values[j] > tmp) {
        values[j + 1] = values[j]
        j--
      }
      values[j + 1] = tmp
    }
  }
  function nearest_rank(values, count, percent,    rank) {
    if (count < 1) return 0
    rank = int((count * percent + 99) / 100)
    if (rank < 1) rank = 1
    if (rank > count) rank = count
    return values[rank]
  }
  BEGIN {
    expected = 30
    current = 0
    sample_gate = 1
    function_gate = 1
    timing_gate = 1
    zy_pid_gate = 1
    ts_pid_gate = 1
    transport_gate = 1
  }
  /^MINUTE=[0-9]+[[:space:]]/ {
    current = value("MINUTE") + 0
    starts[current]++
    start_total++
    next
  }
  /^MINUTE_END=[0-9]+[[:space:]]/ {
    ended = value("MINUTE_END") + 0
    ends[ended]++
    end_total++
    next
  }
  /^ZY101_RC=/ {
    zy_rc_count[current]++
    zy_rc[current] = value("ZY101_RC")
    next
  }
  /^TS171_RC=/ {
    ts_rc_count[current]++
    ts_rc[current] = value("TS171_RC")
    next
  }
  /^ZY101 PASS=/ {
    result_count[current]++
    pass_value[current] = value("PASS")
    home[current] = value("HOME50")
    home_provider[current] = value("HP")
    home_status[current] = value("HS")
    app[current] = value("APP50")
    request[current] = value("REQ20")
    color[current] = value("COLOR")
    app_provider[current] = value("AP")
    app_status[current] = value("AS")
    next
  }
  /^ZY101_PROC / {
    role = value("ROLE")
    pid = value("PID")
    zy_proc_count[current, role]++
    if (role != "" && uint(pid)) {
      zy_pid_seen[role, pid] = 1
    }
    next
  }
  /^TS171_PROC / {
    phase = value("PHASE")
    role = value("ROLE")
    pid = value("PID")
    ts_proc_count[current, phase, role]++
    if (role != "" && uint(pid)) {
      ts_pid_seen[role, pid] = 1
    }
    next
  }
  /SSH_FAIL/ {
    ssh_fail++
  }
  END {
    if (start_total != expected) {
      sample_gate = 0
      add_error("sample starts=" start_total ", expected=" expected)
    }
    if (end_total != expected) {
      sample_gate = 0
      add_error("sample ends=" end_total ", expected=" expected)
    }

    for (minute = 1; minute <= expected; minute++) {
      if (starts[minute] != 1) {
        sample_gate = 0
        add_error("minute " minute " start count=" starts[minute] ", expected=1")
      }
      if (ends[minute] != 1) {
        sample_gate = 0
        add_error("minute " minute " end count=" ends[minute] ", expected=1")
      }
      if (zy_rc_count[minute] != 1 || zy_rc[minute] != "0") {
        transport_gate = 0
        add_error("minute " minute " .101 ssh rc count/value=" zy_rc_count[minute] "/" zy_rc[minute])
      }
      if (ts_rc_count[minute] != 1 || ts_rc[minute] != "0") {
        transport_gate = 0
        add_error("minute " minute " .171 ssh rc count/value=" ts_rc_count[minute] "/" ts_rc[minute])
      }
      if (result_count[minute] != 1) {
        function_gate = 0
        timing_gate = 0
        add_error("minute " minute " .101 result count=" result_count[minute] ", expected=1")
      } else {
        if (pass_value[minute] != "1") {
          function_gate = 0
          add_error("minute " minute " .101 PASS=" pass_value[minute])
        } else {
          function_pass++
        }
        if (color[minute] != "12688231") {
          function_gate = 0
          add_error("minute " minute " color=" color[minute] ", expected=12688231")
        }
        if (!uint(home_provider[minute]) || home_provider[minute] == "8" || home_status[minute] != "0") {
          function_gate = 0
          add_error("minute " minute " Home provider/status=" home_provider[minute] "/" home_status[minute])
        }
        if (app_provider[minute] != "8" || app_status[minute] != "0") {
          function_gate = 0
          add_error("minute " minute " App provider/status=" app_provider[minute] "/" app_status[minute])
        }
        if (!uint(home[minute]) || home[minute] * 50 > 1200) {
          timing_gate = 0
          add_error("minute " minute " Home ms=" (uint(home[minute]) ? home[minute] * 50 : "invalid"))
        }
        if (!uint(app[minute]) || app[minute] * 50 > 1200) {
          timing_gate = 0
          add_error("minute " minute " App ms=" (uint(app[minute]) ? app[minute] * 50 : "invalid"))
        }
        if (!uint(request[minute]) || request[minute] * 20 > 1200) {
          timing_gate = 0
          add_error("minute " minute " request ms=" (uint(request[minute]) ? request[minute] * 20 : "invalid"))
        }
        if (uint(home[minute])) {
          home_count++
          home_values[home_count] = home[minute] * 50
        }
        if (uint(app[minute])) {
          app_count++
          app_values[app_count] = app[minute] * 50
        }
        if (uint(request[minute])) {
          request_count++
          request_values[request_count] = request[minute] * 20
        }
      }

      zy_roles[1] = "framecap"
      zy_roles[2] = "App"
      zy_roles[3] = "SpringBoard"
      for (r = 1; r <= 3; r++) {
        role = zy_roles[r]
        if (zy_proc_count[minute, role] != 1) {
          zy_pid_gate = 0
          add_error("minute " minute " .101 " role " process count=" zy_proc_count[minute, role] ", expected=1")
        }
      }

      ts_roles[1] = "TSDaemon"
      ts_roles[2] = "Hades"
      ts_roles[3] = "SpringBoard"
      ts_roles[4] = "App"
      phases[1] = "before"
      phases[2] = "after"
      for (p = 1; p <= 2; p++) {
        phase = phases[p]
        for (r = 1; r <= 4; r++) {
          role = ts_roles[r]
          if (ts_proc_count[minute, phase, role] != 1) {
            ts_pid_gate = 0
            add_error("minute " minute " .171 " phase " " role " process count=" ts_proc_count[minute, phase,role] ", expected=1")
          }
        }
      }
    }

    for (key in zy_pid_seen) {
      split(key, parts, SUBSEP)
      zy_unique[parts[1]]++
    }
    for (r = 1; r <= 3; r++) {
      role = zy_roles[r]
      if (zy_unique[role] != 1) {
        zy_pid_gate = 0
        add_error(".101 " role " unique PID count=" zy_unique[role] ", expected=1")
      }
    }

    for (key in ts_pid_seen) {
      split(key, parts, SUBSEP)
      ts_unique[parts[1]]++
    }
    for (r = 1; r <= 4; r++) {
      role = ts_roles[r]
      if (ts_unique[role] != 1) {
        ts_pid_gate = 0
        add_error(".171 " role " unique PID count=" ts_unique[role] ", expected=1")
      }
    }

    if (ssh_fail != 0) {
      transport_gate = 0
      add_error("SSH_FAIL lines=" ssh_fail ", expected=0")
    }

    sort_values(home_values, home_count)
    sort_values(app_values, app_count)
    sort_values(request_values, request_count)

    verdict = sample_gate && function_gate && timing_gate && zy_pid_gate && ts_pid_gate && transport_gate
    print "ANALYZER=zy_p2_strict_analyze_v2"
    print "ANALYZED_TS=" analysis_ts
    print "EXPECTED_SAMPLES=" expected
    print "SAMPLE_STARTS=" (start_total + 0)
    print "SAMPLE_ENDS=" (end_total + 0)
    print "ZY101_PASS_SAMPLES=" (function_pass + 0)
    print "SSH_FAIL=" (ssh_fail + 0)
    print "HOME_MS_P50=" nearest_rank(home_values, home_count, 50)
    print "HOME_MS_P95=" nearest_rank(home_values, home_count, 95)
    print "HOME_MS_MAX=" (home_count ? home_values[home_count] : 0)
    print "APP_MS_P50=" nearest_rank(app_values, app_count, 50)
    print "APP_MS_P95=" nearest_rank(app_values, app_count, 95)
    print "APP_MS_MAX=" (app_count ? app_values[app_count] : 0)
    print "REQ_MS_P50=" nearest_rank(request_values, request_count, 50)
    print "REQ_MS_P95=" nearest_rank(request_values, request_count, 95)
    print "REQ_MS_MAX=" (request_count ? request_values[request_count] : 0)
    print "GATE_SAMPLE_COUNT=" gate_text(sample_gate)
    print "GATE_COLOR_PROVIDER_STATUS=" gate_text(function_gate)
    print "GATE_HOME_APP_REQ_1200MS=" gate_text(timing_gate)
    print "GATE_ZY101_PID_UNIQUE=" gate_text(zy_pid_gate)
    print "GATE_TS171_PID_UNIQUE=" gate_text(ts_pid_gate)
    print "GATE_SSH_COMPLETE=" gate_text(transport_gate)
    print "ERROR_COUNT=" (errors + 0)
    for (i = 1; i <= errors; i++) {
      printf "ERROR_%03d=%s\n", i, error_text[i]
    }
    print "VERDICT=" (verdict ? "PASS" : "FAIL")
    exit(verdict ? 0 : 1)
  }
  ' "$LOG"
}

if test -z "$SUMMARY"; then
  run_analysis
  exit $?
fi

mkdir -p "$(dirname -- "$SUMMARY")"
summary_tmp="$SUMMARY.tmp.$$"
if run_analysis > "$summary_tmp"; then
  rc=0
else
  rc=$?
fi
mv "$summary_tmp" "$SUMMARY"
cat "$SUMMARY"
exit "$rc"
