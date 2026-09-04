#!/usr/bin/env python3
"""Create/read the small persistent checkpoint used to resume ZiYan Codex work."""
import argparse, json, subprocess, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
STATE=ROOT/'.codex'/'ZIYAN_ACTIVE_CHECKPOINT.json'
WORKTREE_STATE=Path('/Users/mac/.codex/worktrees/edf5/ZiYan_副本/.codex/ZIYAN_ACTIVE_CHECKPOINT.json')
def git(args):
    return subprocess.run(['git',*args],cwd=ROOT,text=True,capture_output=True).stdout.strip()
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('action',choices=['show','write'])
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
    if a.action=='show':
        if STATE.exists():
            print(STATE.read_text()); return
        if WORKTREE_STATE.exists():
            print(WORKTREE_STATE.read_text()); return
        print('CHECKPOINT_MISSING'); return
    if not all((a.stage,a.last_command,a.result,a.next_action)):
        ap.error('write requires --stage --last-command --result --next-action')
    STATE.parent.mkdir(parents=True,exist_ok=True)
    d={'schemaVersion':2,'updatedAt':int(time.time()),'stage':a.stage,
       'head':git(['rev-parse','HEAD']),'changedFiles':git(['status','--short']).splitlines(),
       'lastSuccessfulCommand':a.last_command,'literalResult':a.result,
       'evidence':a.evidence,'latestVerdict':a.latest_verdict,
       'artifacts':{'packageVersion':a.package_version,'packageSha256':a.package_sha256},
       'deviceState':a.device_state,'runningProcesses':a.running_processes,
       'cleanupStatus':a.cleanup_status,'unfinished':True,'nextAction':a.next_action,
       'deviceOrder':['.101','.112','.166','.53']}
    t=STATE.with_suffix('.tmp');t.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n');t.replace(STATE)
    print(STATE)
if __name__=='__main__': main()
