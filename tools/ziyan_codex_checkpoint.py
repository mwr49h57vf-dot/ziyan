#!/usr/bin/env python3
"""Create/read the small persistent checkpoint used to resume ZiYan Codex work."""
import argparse, json, subprocess, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
STATE=ROOT/'.codex'/'ZIYAN_ACTIVE_CHECKPOINT.json'
def git(args):
    return subprocess.run(['git',*args],cwd=ROOT,text=True,capture_output=True).stdout.strip()
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('action',choices=['show','write'])
    ap.add_argument('--state',default='',help='override checkpoint path (tests must not touch the real one)')
    ap.add_argument('--unfinished', dest='unfinished', action=argparse.BooleanOptionalAction,
                    default=True, help='set checkpoint completion state')
    ap.add_argument('--stage',default=''); ap.add_argument('--last-command',default='')
    ap.add_argument('--result',default=''); ap.add_argument('--next-action',default='')
    ap.add_argument('--evidence',default='')
    ap.add_argument('--latest-verdict',default='NOT_RECORDED')
    ap.add_argument('--package-version',default='NOT_RECORDED')
    ap.add_argument('--package-sha256',default='NOT_RECORDED')
    ap.add_argument('--device-state',default='NOT_RECORDED')
    ap.add_argument('--running-processes',default='NOT_RECORDED')
    ap.add_argument('--cleanup-status',default='NOT_RECORDED')
    a=ap.parse_args()
    state=Path(a.state) if a.state else STATE
    if a.action=='show':
        if state.exists():
            print(state.read_text()); return
        print('CHECKPOINT_MISSING'); return
    if not all((a.stage,a.last_command,a.result,a.next_action)):
        ap.error('write requires --stage --last-command --result --next-action')
    state.parent.mkdir(parents=True,exist_ok=True)
    d={'schemaVersion':2,'updatedAt':int(time.time()),'stage':a.stage,
       'head':git(['rev-parse','HEAD']),'changedFiles':git(['status','--short']).splitlines(),
       'lastSuccessfulCommand':a.last_command,'literalResult':a.result,
       'evidence':a.evidence,'latestVerdict':a.latest_verdict,
       'artifacts':{'packageVersion':a.package_version,'packageSha256':a.package_sha256},
       'deviceState':a.device_state,'runningProcesses':a.running_processes,
       'cleanupStatus':a.cleanup_status,'unfinished':a.unfinished,'nextAction':a.next_action,
       'deviceOrder':['.101','.112','.166','.53','.61']}
    t=state.with_suffix('.tmp');t.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n');t.replace(state)
    print(state)
if __name__=='__main__': main()
